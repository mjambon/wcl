(*
  Line count with estimation of total number of lines.
*)

open Printf

(*
  Int64 support - all file sizes use int64 in order to avoid reaching
  the 1GB limit on 32-bit platforms.
*)
module F = Unix.LargeFile
let ( ++ ) = Int64.add
let ( -- ) = Int64.sub
let ( // ) = Int64.div
let ( %% ) = Int64.rem


let refresh_interval = ref 20_000_000L (* bytes *)

let count_display_width = ref (-1)

let rec select f = function
    [] -> []
  | x :: l ->
      match f x with
          None -> select f l
        | Some y -> y :: select f l

let readable_string_of_int64 n =
  let rec loop digits n =
    if n < 0L then "-" ^ loop digits (Int64.neg n)
    else if n = 0L then "0"
    else
      let s = Int64.to_string (n %% 10L) in
      let n = n // 10L in
      if n <> 0L then
        let sep =
          if (digits+1) mod 3 = 0 then ","
          else ""
        in
        loop (digits+1) n ^ sep ^ s
      else s
  in
  loop 0 n

let get_info fname =
  let x = F.stat fname in
  if x.F.st_kind <> Unix.S_REG then (
    eprintf "Ignoring %S: not a regular file\n%!" fname;
    None
  )
  else
    Some (fname, x)

let get_total_bytes l =
  List.fold_left (fun acc (fname, x) ->
                    Int64.add acc x.F.st_size) 0L l

type progress_data = {
  mutable byte_progress : int64;
  mutable progress_string : string;
  mutable progress_is_displayed : bool;
}

let string_of_progress total_bytes fname bytes lines =
  let progress = Int64.to_float bytes /. Int64.to_float total_bytes in
  let total_lines = Int64.of_float (Int64.to_float lines /. progress) in
  if !count_display_width < 0 then
    count_display_width :=
      String.length (readable_string_of_int64 (Int64.mul 5L total_lines));
  sprintf "%3.0f%% [%s] projected line count: %s "
    (100. *. progress)
    (Filename.basename fname)
    (readable_string_of_int64 total_lines)

let update_progress_data pd total_bytes fname bytes lines =
  pd.byte_progress <- bytes;
  pd.progress_string <- string_of_progress total_bytes fname bytes lines

let print_progress pd =
  if not pd.progress_is_displayed then (
    printf "%s%!" pd.progress_string;
    pd.progress_is_displayed <- true
  )

let clear_progress pd =
  if pd.progress_is_displayed then (
    printf "\r\x1B[K%!";
    pd.progress_is_displayed <- false
  )

let refresh_progress pd total_bytes fname bytes lines =
  update_progress_data pd total_bytes fname bytes lines;
  clear_progress pd;
  print_progress pd

let find_lines_in_chunk
    pd total_bytes initial_bytes initial_lines fname buf len =
  let local_lines = ref 0L in
  for i = 0 to len - 1 do
    match String.unsafe_get buf i with
        '\n' ->
          local_lines := !local_lines ++ 1L;
          let byte_progress = initial_bytes ++ Int64.of_int i in
          if byte_progress -- pd.byte_progress >= !refresh_interval then (
            refresh_progress
              pd
              total_bytes
              fname
              byte_progress
              (initial_lines ++ !local_lines)
          )
      | _ -> ()
  done;
  !local_lines

let refill fd buf =
  let maxlen = String.length buf in
  let len = Unix.read fd buf 0 maxlen in
  assert (len >= 0);
  len

let rec read_file pd total_bytes initial_bytes initial_lines fname fd buf =
  match refill fd buf with
      0 -> initial_lines
    | chunk_bytes ->
        let chunk_lines =
          find_lines_in_chunk
            pd total_bytes initial_bytes initial_lines fname buf chunk_bytes
        in
        read_file
          pd
          total_bytes
          (initial_bytes ++ Int64.of_int chunk_bytes)
          (initial_lines ++ chunk_lines)
          fname fd buf 

let count pd total_bytes initial_bytes initial_lines fname =
  let fd = Unix.openfile fname [Unix.O_RDONLY] 0 in
  try
    let buf = String.create (1024 * 1024) in
    let lines =
      read_file pd total_bytes initial_bytes initial_lines fname fd buf in
    Unix.close fd;
    lines
  with e ->
    (try Unix.close fd with _ -> ());
    raise e

let string_of_count n =
  let count_s = readable_string_of_int64 n in
  if !count_display_width < 0 then
    count_display_width := 10;
  let blank =
    let len = max 0 (!count_display_width - String.length count_s) in
    String.make len ' '
  in
  blank ^ count_s

let main () =
  let options = [
    "-version", Arg.Unit (fun () -> print_endline Wcl_version.version; exit 0),
    "
          Print wcl version and exit.";

    "-p", Arg.Int (fun i -> refresh_interval := Int64.of_int i),
    "<every>
          Refresh progress indicator every so many bytes (default: 100 MB)";
  ]
  in
  let usage_msg = sprintf "\
Usage: %s [OPTIONS] FILE1 [FILE2 ...]

wcl is a replacement for \"wc -l\" useful for interactive use
with large data files. Like \"wc -l\" it counts the number of lines
in files and displays the total. Unlike \"wc -l\", wcl displays a progress 
meter and an estimate of the total number of lines as it progresses.


Options:
"
    Sys.argv.(0)
  in
  let files = ref [] in
  let anon_fun s =
    files := s :: !files in
  Arg.parse options anon_fun usage_msg;

  let files = List.rev !files in
  let l = select get_info files in
  let total_bytes = get_total_bytes l in
  let pd = {
    byte_progress = 0L;
    progress_string = "";
    progress_is_displayed = true
  }
  in
  let _, total_lines =
    List.fold_left (
      fun (bytes0, lines0) (fname, info) ->
        let lines = count pd total_bytes bytes0 lines0 fname in
        let file_lines = lines -- lines0 in
        clear_progress pd;
        printf "%s %s\n%!" (string_of_count file_lines) fname;
        print_progress pd;
        (bytes0 ++ info.F.st_size, lines)
    ) (0L, 0L) l
  in
  clear_progress pd;
  printf "%s total\n%!" (string_of_count total_lines)

let () =
  try
    Unix.handle_unix_error main ()
  with e ->
    eprintf "Error: %s\n%!" (Printexc.to_string e);
    exit 1
