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

(** Streaming a playlist *)

open Source
open Dtools

(* Random: every file is choosed randomly.
 * Randomize: the playlist is shuffled, then read linearly,
 *            and shuffled again when the end is reached, and so on.
 * Normal: the playlist is read normally, and loops. *)
type random_mode = Random | Randomize | Normal


(* Never: never reload the playlist.
 * With the other reloading modes, reloading may be triggered after a file
 * is choosed -- it requires the source to be selected:
 * Every_N_seconds n: the playlist is reloaded every n seconds;
 * Every_N_rounds n: A round is every time the end of playlist is reached
 *                   (only defined for Normal and Randomize modes).
 *)
type reload_mode = Never | Every_N_rounds of int | Every_N_seconds of float

let rev_array_of_list l =
  let n = List.length l in
  let a = Array.make n "" in
    ignore (List.fold_left
              (fun i e ->
                 a.(i) <- e ; i-1) (n-1) l) ;
    a

let is_dir f =
  try
    (Unix.stat f).Unix.st_kind = Unix.S_DIR
  with
    | _ -> false

let rec list_files (log : Log.t) dir =
  let dirs, files =
    List.partition is_dir
      (List.map
         (fun s -> dir ^ "/" ^ s)
         (Array.to_list
            (
              try
                Sys.readdir dir
              with
                | Sys_error _ ->
                    log#f 3 "Could not read directory %s" dir ;
                    [||]
            )
         )
      )
  in
    files@(List.concat (List.map (fun d -> list_files log d) dirs))

class virtual vplaylist ~mime ~reload 
                       ~random ~timeout 
                       ~prefix playlist_uri =
object (self)

  method virtual is_valid : string -> bool
  method virtual stype : Source.source_t
  method virtual id : string
  method virtual set_id : ?definitive:bool -> string -> unit
  method virtual copy_queue : Request.audio Request.t list
  method virtual create_request :
    ?metadata:((string*string) list) ->
    ?persistent:bool ->
    ?indicators:(Request.indicator list) -> string ->
    Request.audio Request.t option
  method virtual log : Dtools.Log.t

  (** How to get the playlist. *)
  val mutable playlist_uri = playlist_uri

  (** Current playlist, containing the same files, but possibly shuffled. *)
  val playlist = ref [| |]

  (** Index of the current file. *)
  val mutable index_played = -1

  (** Random mode. *)
  val mutable random = random

  (** Reload mode with reload status in term of rounds and time. *)
  val mutable reload = reload
  val mutable round_c = 0
  val mutable reload_t = 0.

  (** Lock for the previous variables. *)
  val mylock = Mutex.create ()

  (** Lock for avoiding multiple reloads at the same time. *)
  val reloading = Mutex.create ()

  (** Randomly exchange files in the playlist.
    * Must be called within mylock critical section. *)
  method randomize_playlist =
    assert (not (Mutex.try_lock mylock)) ;
    Utils.randomize !playlist

  (** (re-)read playlist_file and update datas.
    [reload] should be true except on first load, in that case playlist
    resolution failures won't result in emptying the current playlist.*)
  method load_playlist ?(uri=playlist_uri) reload =
    let _playlist =
      let read_playlist filename =
        if is_dir filename then begin
          self#log#f 3 "Playlist is a directory" ;
          List.filter self#is_valid (list_files self#log filename)
        end else
          try
            let channel = open_in filename in
            let length = in_channel_length channel in
            let content = String.create length in
              really_input channel content 0 length;
              (* Close the file now, I don't need it anymore.. *)
              close_in channel ;
              let (format,playlist) =
                match mime with
                  | "" ->
                      self#log#f 3
                        "No mime type specified, trying autodetection." ;
                      Playlist_parser.search_valid content
                  | x ->
                      begin match Playlist_parser.parsers#get x with
                        | Some plugin ->
                            (x,plugin.Playlist_parser.parser content)
                        | None ->
                            self#log#f 3
                              "Unknown mime type, trying autodetection." ;
                            Playlist_parser.search_valid content
                      end
              in
                self#log#f 3 "Playlist treated as format %s" format  ;
                List.map (fun (_,x) -> x) playlist
          with
            | e ->
                self#log#f 3
                  "Could not parse playlist: %s" (Printexc.to_string e) ;
                []
      in
        self#log#f 3 "Loading playlist..." ;
        match Request.create_raw uri with
          | None ->
              self#log#f 2 "Could not resolve playlist URI %S!" uri ;
              []
          | Some req ->
              match Request.resolve req timeout with
                | Request.Resolved ->
                    let l =
                      read_playlist (Utils.get_some (Request.get_filename req))
                    in
                    Request.destroy req ;
                    l
                | e ->
                    let reason =
                      match e with
                        | Request.Timeout -> "Timeout"
                        | Request.Failed -> "Failed"
                        | Request.Resolved -> assert false
                    in
                    self#log#f 2
                      "%s when resolving playlist URI %S!"
                      reason uri ;
                    Request.destroy req ;
                    []
    in
    (* Add prefix to all requests. *)
    let _playlist = 
      List.map (Printf.sprintf "%s%s" prefix) _playlist
    in
      (* TODO distinguish error and empty if fallible *)
      if _playlist = [] && reload then
        self#log#f 3 "Got an empty list: keeping the old one."
      else begin
        (* Don't worry if a reload fails,
         * otherwise, the source type must be aware of the failure *)
        Mutex.lock mylock ;
        assert (not (self#stype = Infallible && _playlist = [])) ;
        playlist := rev_array_of_list _playlist ;
        playlist_uri <- uri ;
        (* The only case where keeping the old index is safe and makes sense *)
        if not (random = Normal && index_played < Array.length !playlist) then
          index_played <- -1 ;
        Mutex.unlock mylock ;
        self#log#f 3
          "Successfully loaded a playlist of %d tracks."
          (Array.length !playlist)
      end

  (* [reloading] avoids two reloadings being prepared at the same time. *)
  method reload_playlist ?new_reload ?new_random ?new_playlist_uri () =
      Duppy.Task.add Tutils.scheduler 
        { Duppy.Task.
	    priority = Tutils.Maybe_blocking ;
            events   = [`Delay 0.] ;
            handler  = (fun _ ->
              if Mutex.try_lock reloading then
                begin
                  self#reload_playlist_internal
                    new_reload new_random new_playlist_uri ;
                  Mutex.unlock reloading 
                end ;
              []) }

  method reload_playlist_nobg ?new_reload ?new_random ?new_playlist_uri () =
    if Mutex.try_lock reloading then
      ( self#reload_playlist_internal new_reload new_random new_playlist_uri ;
        Mutex.unlock reloading )

  method reload_playlist_internal new_reload new_random new_playlist_uri =

    assert (not (Mutex.try_lock reloading)) ;

    self#load_playlist ?uri:new_playlist_uri true ;

    Mutex.lock mylock ;
    ( match new_random with
        | None -> ()
        | Some m -> random <- m ) ;
    ( match new_reload with
        | None -> ()
        | Some m -> reload <- m ) ;
    if Randomize = random then
      self#randomize_playlist ;
    ( match reload with
        | Never -> ()
        | Every_N_rounds n -> round_c <- n
        | Every_N_seconds n -> reload_t <- Unix.time () ) ;
    Mutex.unlock mylock

  method reload_update round_done =
    (* Must be called by somebody who owns [mylock] *)
    assert (not (Mutex.try_lock mylock)) ;
    match reload with
      | Never -> ()
      | Every_N_seconds n ->
          if Unix.time () -. reload_t > n then
            self#reload_playlist ()
      | Every_N_rounds n ->
          if round_done then round_c <- round_c - 1 ;
          if round_c <= 0 then
            self#reload_playlist ()

  method get_next_request : Request.audio Request.t option =
    Mutex.lock mylock ;
    if !playlist = [||] then
      ( self#reload_update true ;
        Mutex.unlock mylock ;
        None )
    else
      let uri =
        match random with
          | Randomize ->
              index_played <- index_played + 1 ;
              let round =
                if index_played >= Array.length !playlist
                then ( index_played <- 0 ;
                       self#randomize_playlist ;
                       true )
                else false
              in
                self#reload_update round ;
                !playlist.(index_played)
          | Random ->
              index_played <- Random.int (Array.length !playlist) ;
              self#reload_update false ;
              !playlist.(index_played)
          | Normal ->
              index_played <- index_played + 1 ;
              let round =
                if index_played >= Array.length !playlist
                then ( index_played <- 0 ; true )
                else false
              in
                self#reload_update round ;
                !playlist.(index_played)
      in
        Mutex.unlock mylock ;
        self#create_request uri

  val mutable ns = []
  method playlist_wake_up =
    let base_name =
      let x = Filename.basename playlist_uri in
      match x with
        | "." ->
            begin
              match List.rev (Pcre.split ~pat:"/" playlist_uri) with
                | e :: _ -> e
                | [] -> Filename.dirname playlist_uri
            end
        | _ -> x
    in
    let id =
      match base_name with
        | "." -> (* Definitly avoid this *)
            Printf.sprintf "playlist-%s" playlist_uri
        | _ -> base_name
    in
    self#set_id ~definitive:false id ;
    self#reload_playlist_nobg () ;
    if ns = [] then
      ns <- Server.register [self#id] "playlist" ;
    Server.add ~ns "next" ~descr:"Return up to 10 next URIs to be played."
      (* The next command returns up to 10 next URIs to be played.
       * We cannot return request ids cause we create requests at the last
       * moment. We get requests from Request_source.* classes, from which
       * we get a status. *)
      (fun s ->
         let n =
           try int_of_string s with _ -> 10
         in
           Array.fold_left
             (fun s uri -> s^uri^"\n")
             (List.fold_left
                (fun s r ->
                   let get s =
                     match Request.get_metadata r s with
                       | Some s -> s | None -> "?"
                   in
                     (Printf.sprintf "[%s] %s\n"
                        (get "status") (get "initial_uri"))
                     ^ s)
                "" self#copy_queue)
             (self#get_next n))

  (* Give the next [n] URIs, if guessing is easy. *)
  method get_next = Tutils.mutexify mylock (fun n ->
    match random with
    | Normal ->
        Array.init
          n
          (fun i -> !playlist.((index_played+i+1) mod (Array.length !playlist)))
    | Randomize ->
        Array.init
          (min n (Array.length !playlist - index_played - 1))
          (fun i -> !playlist.(index_played+i+1))
    | Random -> [||])

end

(** Standard playlist, with a queue. *)
class playlist ~mime ~reload 
               ~random ~length 
               ~default_duration
               ~timeout ~prefix 
               uri =
object

  inherit vplaylist ~mime ~reload 
                    ~random ~timeout 
                    ~prefix uri as pl
  inherit Request_source.queued 
            ~length ~default_duration 
            ~timeout () as super

  method reload_playlist_internal a b c =
    pl#reload_playlist_internal a b c ;
    super#notify_new_request

  method wake_up activation =
    (* The queued request source should be prepared first,
     * because the loading of the playlist triggers a notification to it. *)
    super#wake_up activation ;
    pl#playlist_wake_up

  (** Assume that every URI is valid, it will be checked on queuing. *)
  method is_valid file = true

end

(** Safe playlist, without queue and playing only local files,
  * which never fails. *)
class safe_playlist ~mime ~reload ~random
                   ~timeout ~prefix local_playlist =
object (self)

  inherit vplaylist ~mime ~reload ~random
                    ~timeout ~prefix 
                    local_playlist as pl
  inherit Request_source.unqueued as super

  method wake_up =
    pl#playlist_wake_up ;
    super#wake_up

  (** We check that the lines are valid local files,
    * thus, we can assume that the source is infallible. *)
  method is_valid uri =
    Sys.file_exists uri &&
    match Request.create uri with
      | None -> assert false
      | Some r ->
          let check = Request.resolve r 0. = Request.Resolved in
            Request.destroy r ;
            check

  method stype = Infallible

  method load_playlist ?uri reload =
    pl#load_playlist ?uri reload ;
    if Array.length !playlist = 0
    then failwith "Empty default playlist !" ;

  (** Directly play the files of the playlist. *)
  method get_next_file = pl#get_next_request

end


let () =

  let proto =
    [ "mode",
      Lang.string_t,
      (Some (Lang.string "randomize")),
      Some "Play the files in the playlist either in the order (\"normal\" \
            mode), or shuffle the playlist and play it in this order \
            (\"randomize\" mode), or pick a random file in the playlist \
            each time (\"random\" mode)." ;
      "reload",
      Lang.int_t,
      Some (Lang.int 0),
      Some "Amount of time (in seconds or rounds) before which \
            the playlist is reloaded; 0 means never." ;

      "reload_mode",
      Lang.string_t,
      Some (Lang.string "seconds"),
      Some "Unit of the reload parameter, either 'rounds' or 'seconds'." ;

      "mime_type",
      Lang.string_t,
      Some (Lang.string ""),
      Some "Default MIME type for the playlist. \
            Empty string means automatic detection." ;

      "prefix",
      Lang.string_t,
      Some (Lang.string ""),
      Some "Add a constant prefix to all requests. \
            Usefull for passing extra information using annotate, \
            or for resolution through a particular protocol, such \
            as replaygain." ;

      "timeout",
      Lang.float_t,
      Some (Lang.float 20.),
      Some "Timeout (in seconds) for a single download." ;

      "",
      Lang.string_t,
      None,
      Some "URI where to find the playlist." ]
  in
  let reload_of i s =
    let arg = Lang.to_int i in
      if arg<0 then
        raise (Lang.Invalid_value (i,"must be positive")) ;
      if arg = 0 then Never else
      begin match Lang.to_string s with
        | "rounds"  -> Every_N_rounds arg
        | "seconds" -> Every_N_seconds (float_of_int arg)
        | _ ->
            raise (Lang.Invalid_value
                     (s,"valid values are 'rounds' and 'seconds'"))
      end
  in
  let random_of s =
    match Lang.to_string s with
      | "random" -> Random
      | "randomize" -> Randomize
      | "normal" -> Normal
      | _ ->
          raise (Lang.Invalid_value
                   (s,"valid values are 'random', 'randomize' and 'normal'"))
  in

    Lang.add_operator "playlist"
      ~category:Lang.Input
      ~descr:"Loop on a playlist of URIs."
      (Request_source.queued_proto@proto)
      (fun params ->
         let reload,random,timeout,mime,uri,prefix =
           let e v = List.assoc v params in
             (reload_of (e "reload") (e "reload_mode")),
             (random_of (e "mode")),
             (Lang.to_float (e "timeout")),
             (Lang.to_string (e "mime_type")),
             (Lang.to_string (e "")),
             (Lang.to_string (e "prefix"))
         in
         let length,default_duration,timeout = 
                Request_source.extract_queued_params params 
         in
           ((new playlist ~mime ~reload ~prefix 
                          ~length ~default_duration
                          ~timeout ~random uri):>source)) ;

    Lang.add_operator "playlist.safe"
      ~category:Lang.Input
      ~descr:"Loop on a playlist of local files, \
              and never fail. In order to do so, it has to check \
              every file at the loading, so the streamer startup may take \
              a few seconds. To avoid this, use a standard playlist, \
              and put only a few local files in a default safe_playlist \
              in order to ensure the liveness of the streamer."
      proto
      (fun params ->
          let reload,random,timeout,mime,uri,prefix =
           let e v = List.assoc v params in
             (reload_of (e "reload") (e "reload_mode")),
             (random_of (e "mode")),
             (Lang.to_float (e "timeout")),
             (Lang.to_string (e "mime_type")),
             (Lang.to_string (e "")),
             (Lang.to_string (e "prefix"))
         in
           ((new safe_playlist ~mime ~reload ~prefix
                               ~random ~timeout uri):>source))