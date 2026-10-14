(* Numeric helpers, CSV and filesystem utilities. *)

let clip lo hi x = if x < lo then lo else if x > hi then hi else x
let sum a = Array.fold_left ( +. ) 0. a
let mean a = if Array.length a = 0 then nan else sum a /. float_of_int (Array.length a)

let variance a =
  let n = Array.length a in
  if n < 2 then nan
  else
    let m = mean a in
    Array.fold_left (fun acc x -> acc +. ((x -. m) *. (x -. m))) 0. a /. float_of_int (n - 1)

let std a = sqrt (variance a)
let finite a = List.filter Float.is_finite (Array.to_list a) |> Array.of_list

let quantile a q =
  let n = Array.length a in
  if n = 0 then nan
  else begin
    let s = Array.copy a in
    Array.sort compare s;
    let pos = q *. float_of_int (n - 1) in
    let i = int_of_float (Float.floor pos) in
    let j = min (n - 1) (i + 1) in
    s.(i) +. ((pos -. float_of_int i) *. (s.(j) -. s.(i)))
  end

let sub_last a n =
  let len = Array.length a in
  let n = min n len in
  Array.sub a (len - n) n

let norm_pdf z = exp (-0.5 *. z *. z) /. sqrt (2. *. Float.pi)
let safe_div a b = if Float.is_finite a && Float.is_finite b && b > 0. then a /. b else nan

(* ---------- CSV ---------- *)

let split_csv_line line =
  let buf = Buffer.create 32 in
  let fields = ref [] in
  let in_q = ref false in
  String.iter
    (fun ch ->
      match ch with
      | '"' -> in_q := not !in_q
      | ',' when not !in_q ->
          fields := Buffer.contents buf :: !fields;
          Buffer.clear buf
      | '\r' -> ()
      | c -> Buffer.add_char buf c)
    line;
  fields := Buffer.contents buf :: !fields;
  Array.of_list (List.rev_map String.trim !fields)

let read_lines path = In_channel.with_open_text path In_channel.input_all |> String.split_on_char '\n'

type csv = { header : string array; rows : string array list }

let read_csv path =
  let keep l =
    let t = String.trim l in
    t <> "" && t.[0] <> '#'
  in
  match List.filter keep (read_lines path) with
  | [] -> failwith (path ^ ": empty CSV")
  | h :: rest ->
      { header = Array.map String.lowercase_ascii (split_csv_line h); rows = List.map split_csv_line rest }

let col csv name =
  let rec find i =
    if i >= Array.length csv.header then None else if csv.header.(i) = name then Some i else find (i + 1)
  in
  find 0

let col_exn csv path name =
  match col csv name with
  | Some i -> i
  | None -> failwith (Printf.sprintf "%s: missing column '%s'" path name)

let float_field row = function
  | None -> nan
  | Some i when i < Array.length row -> Option.value (float_of_string_opt row.(i)) ~default:nan
  | Some _ -> nan

let string_field row i = if i < Array.length row then row.(i) else ""

(* ---------- files ---------- *)

let write_file path s = Out_channel.with_open_text path (fun oc -> output_string oc s)

let rec mkdir_p d =
  if d <> "" && d <> "." && d <> "/" && not (Sys.file_exists d) then begin
    mkdir_p (Filename.dirname d);
    Sys.mkdir d 0o755
  end

(* ---------- formatting ---------- *)

let pct x = if Float.is_finite x then Printf.sprintf "%.2f%%" (100. *. x) else "n/a"
let spct x = if Float.is_finite x then Printf.sprintf "%+.2f%%" (100. *. x) else "n/a"

(* set from config; "₹" switches to Indian lakh/crore digit grouping (12,34,567) *)
let currency = ref "$"

let money x =
  if not (Float.is_finite x) then "n/a"
  else begin
    let neg = x < 0. in
    let s = Printf.sprintf "%.0f" (Float.abs x) in
    let n = String.length s in
    let indian = !currency = "₹" || !currency = "Rs" in
    let sep i = let k = n - i in if indian then k = 3 || (k > 3 && (k - 3) mod 2 = 0) else k mod 3 = 0 in
    let b = Buffer.create (n + (n / 2) + 4) in
    String.iteri
      (fun i c ->
        if i > 0 && sep i then Buffer.add_char b ',';
        Buffer.add_char b c)
      s;
    (if neg then "-" else "") ^ !currency ^ Buffer.contents b
  end

(* display width of a UTF-8 string (counts code points, not bytes) *)
let width s = String.fold_left (fun a c -> if Char.code c land 0xC0 = 0x80 then a else a + 1) 0 s

(* right-align to [w] columns; Printf's %Ns counts bytes, which breaks on "₹" *)
let rpad w s = String.make (max 0 (w - width s)) ' ' ^ s

let today () =
  let t = Unix.localtime (Unix.time ()) in
  Printf.sprintf "%04d-%02d-%02d" (t.tm_year + 1900) (t.tm_mon + 1) t.tm_mday
