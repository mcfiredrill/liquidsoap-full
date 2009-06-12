(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2009 Savonet team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details, fully stated in the COPYING
  file at the root of the liquidsoap distribution.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

 *****************************************************************************)

open Source
open Dtools

(** Class [unqueued] plays the file given by method [get_next_file]
  * as a request which is ready, i.e. has been resolved.
  * On the top of it we define [queued], which manages a queue of files, feed
  * by resolving in an other thread requests given by [get_next_request]. *)
class virtual unqueued =
object (self)
  inherit source

  (** [get_next_file] is supposed to return "quickly".
    * This means that no resolving should be done here. *)
  method virtual get_next_file : Request.audio Request.t option

  val mutable remaining = 0

  (** These values are protected by [plock]. *)
  val mutable send_metadata = false
  val mutable current = None
  val plock = Mutex.create ()

  (** How to unload a request. *)
  method private end_track =
    Mutex.lock plock ;
    begin match current with
        | None -> ()
        | Some (request,_,close) ->
            begin match Request.get_filename request with
              | None ->
                  self#log#f 1
                    "Finished with a non-existent file ?! \
                     Something may have been moved or destroyed \
                     during decoding. It is VERY dangerous, avoid it !"
              | Some f -> self#log#f 3 "Finished with %S" f
            end ;
            close () ;
            Request.destroy request
    end ;
    current <- None ;
    remaining <- 0 ;
    Mutex.unlock plock

  (** Load a request.
    * Should be called within critical section,
    * when there is no ready request. *)
  method private begin_track =
    assert (not (Mutex.try_lock plock)) ;
    assert (current = None) ;
    match self#get_next_file with
      | None ->
          self#log#f 6 "Failed to prepare track: no file" ;
          false
      | Some req when Request.is_ready req ->
          (* [Request.is_ready] ensures that we can get a filename from
           * the request, and it can be decoded. *)
          let file = Utils.get_some (Request.get_filename req) in
          let decoder = Utils.get_some (Request.get_decoder req) in
            self#log#f 3 "Prepared %S -- rid %d" file (Request.get_id req) ;
            current <-
              Some (req,
                    (fun buf -> (remaining <- decoder.Decoder.fill buf)),
                    decoder.Decoder.close) ;
            remaining <- (-1) ;
            send_metadata <- true ;
            true
      | Some req ->
          (* We got an unresolved request.. this shoudn't actually happen *)
          self#log#f 1 "Failed to prepare track: unresolved request" ;
          Request.destroy req ;
          false

  (** Now we can write the source's methods. *)

  val mutable must_fail = false

  method is_ready =
    Mutex.lock plock ;
    let ans = current <> None || must_fail || self#begin_track in
      Mutex.unlock plock ;
      ans

  method remaining = remaining

  method private get_frame buf =
    if must_fail then begin
      must_fail <- false ;
      Frame.add_break buf (Frame.position buf)
    end else begin
      let rec try_get () =
        match current with
          | None ->
              if self#begin_track then try_get ()
          | Some (req,get_frame,_) ->
              if send_metadata then begin
                Request.on_air req ;
                let m = Request.get_all_metadata req in
                Frame.set_metadata buf
                  (Frame.position buf) m;
                send_metadata <- false
              end ;
              get_frame buf
      in
        Mutex.lock plock ;
        try_get () ;
        Mutex.unlock plock ;
        if Frame.is_partial buf then self#end_track
    end

  method abort_track =
    self#end_track ;
    must_fail <- true

  method private sleep = self#end_track

  method copy_queue =
    match current with
    | None -> []
    | Some (r,_,_) -> [r]

end

(* Private types for request resolutions *)
type resolution = Empty | Retry | Finished

(* Scheduler priority for request resolutions. *)
let priority = Tutils.Maybe_blocking

(** Same thing, with a queue in which we prefetch files,
  * which requests are given by [get_next_request].
  * Heuristical settings determining how the source feeds its queue:
  * - the source tries to have more than [length] seconds in queue
  * - if the duration of a file is unknown we use [default_duration] seconds
  * - downloading a file is required to take less than [timeout] seconds *)
class virtual queued 
  ?(length=10.) ?(default_duration=30.) 
  ?(conservative=false) ?(timeout=20.) () =
object (self)
  inherit unqueued as super

  method virtual get_next_request : Request.audio Request.t option

  (** Management of the queue of files waiting to be played. *)
  val min_queue_length = Fmt.ticks_of_seconds length
  val qlock = Mutex.create ()
  val retrieved = Queue.create ()
  val mutable queued_length = 0 (* Frames *)
  method private queue_length = 
    if not conservative then
      queued_length + super#remaining
     else
      queued_length
  val mutable resolving = None

  val mutable task = None
  val task_m = Mutex.create ()

  method private create_task = 
    Tutils.mutexify task_m 
    (fun () -> 
      begin
        match task with
          | Some reload -> reload := false 
          | None -> ()
      end ;
      let reload = ref true in
      Duppy.Task.add Tutils.scheduler
        { Duppy.Task.
            priority = priority ;
            events   = [`Delay 0.] ;
            handler  = self#feed_queue reload } ;
      task <- Some reload) ()

  method private stop_task =
    Tutils.mutexify task_m
    (fun () -> 
      begin
        match task with
          | Some reload -> reload := false
          | None -> ()
      end;
      task <- None) ()

  method private wake_up activation =
    assert (task = None) ;
    self#create_task

  method private sleep =
    self#stop_task ;
    (* No more feeding task, we can go to sleep. *)
    super#sleep ;
    begin try
      Mutex.lock qlock ;
      while true do
        let (_,req) = Queue.take retrieved in
          Request.destroy req
      done
    with e -> Mutex.unlock qlock ; if e <> Queue.Empty then raise e end

  (** A function that returns delays for tasks, making sure that these tasks
    * don't repeat too fast.
    * The current scheme is to return 0. as long as there are no more than
    * [max] consecutive occurences separated by less than [delay], otherwise
    * return [delay]. *)
  val adaptative_delay =
    let last   = ref 0. in
    let excess = ref 0  in
    let delay = 2. in
    let max   = 3  in
    let next () =
      let now = Unix.gettimeofday () in
        if now -. !last < delay then incr excess else excess := 0 ;
        last := now ;
        if !excess >= max then delay else 0.
    in
      next

  (** The body of the feeding task *)
  method private feed_queue reload =
    (fun _ -> 
      if !reload && self#queue_length < min_queue_length then
        match self#prefetch with
          | Finished ->
               [{ Duppy.Task.
                   priority = priority ;
                   events   = [`Delay 0.] ;
                   handler  = self#feed_queue reload }]
          | Retry ->
              (* Reschedule the task later *)
              [{ Duppy.Task.
                   priority  = priority ;
                   events   = [`Delay (adaptative_delay ())] ;
                   handler  = self#feed_queue reload }]
          | Empty -> []
      else [])

  (** Try to feed the queue with a new request.
    * Return false if there was no new request to try,
    * true otherwise, whether the request was fetched successfully or not. *)
  method private prefetch =
    match self#get_next_request with
      | None -> Empty
      | Some req ->
          resolving <- Some req ;
          begin match Request.resolve req timeout with
            | Request.Resolved ->
                let len =
                  match Request.get_metadata req "duration" with
                    | Some f ->
                        (try float_of_string f with _ -> default_duration)
                    | None -> default_duration
                in
                let len =
                  int_of_float (len *. float (Fmt.ticks_per_second()))
                in
                  Mutex.lock qlock ;
                  Queue.add (len,req) retrieved ;
                  self#log#f 4 "Remaining : %d, queued: %d, adding : %d (rid %d)"
                    self#queue_length queued_length len (Request.get_id req) ;
                  queued_length <- queued_length + len ;
                  Mutex.unlock qlock ;
                  resolving <- None ;
                  Finished
              | Request.Failed (* Failure of resolving or decoding *)
              | Request.Timeout ->
                  resolving <- None ;
                  Request.destroy req ;
                  Retry
          end

  (** Provide the unqueued [super] with resolved requests. *)
  method private get_next_file =
    Mutex.lock qlock ;
    let ans =
      try
        let len,f = Queue.take retrieved in
          self#log#f 4 "Remaining : %d, queued: %d, taking : %d" 
              self#queue_length queued_length len ;
          queued_length <- queued_length - len ;
          Some f
      with
        | Queue.Empty ->
            self#log#f 6 "Queue is empty !" ;
            None
    in
      Mutex.unlock qlock ;
      ans

  method get ab = 
    super#get ab ;
    if self#queue_length < min_queue_length then
      self#create_task

  method copy_queue =
    Mutex.lock qlock ;
    let q =
      match current with
      | None -> []
      | Some (r,_,_) -> [r]
    in
    let q =
      match resolving with
      | None -> q
      | Some r -> r::q
    in
    let q = Queue.fold (fun l r -> (snd r)::l) q retrieved in
      Mutex.unlock qlock ;
      q

end

let queued_proto =
  [ "length", Lang.float_t, Some (Lang.float 10.),
    Some "How much audio (in sec.) should be downloaded in advance." ;
    "default_duration", Lang.float_t, Some (Lang.float 30.),
    Some "When unknown, assume this duration (in sec.) for files." ;
    "conservative", Lang.bool_t, Some (Lang.bool false),
    Some "If true, estimated remaining time on the current track \
          is not considered when computing queue length." ;
    "timeout", Lang.float_t, Some (Lang.float 20.),
    Some "Timeout (in sec.) for a single download." ]

let extract_queued_params p =
  let l = Lang.to_float (List.assoc "length" p) in
  let d = Lang.to_float (List.assoc "default_duration" p) in
  let t = Lang.to_float (List.assoc "timeout" p) in
  let c = Lang.to_bool (List.assoc "conservative" p) in
    l,d,t,c