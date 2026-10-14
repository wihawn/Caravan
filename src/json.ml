(* Minimal JSON reader/writer for the VolaTTM sidecar protocol. *)

type t = Null | Bool of bool | Num of float | Str of string | Arr of t list | Obj of (string * t) list

let rec write b = function
  | Null -> Buffer.add_string b "null"
  | Bool x -> Buffer.add_string b (if x then "true" else "false")
  | Num f -> Buffer.add_string b (if Float.is_finite f then Printf.sprintf "%.9g" f else "null")
  | Str s ->
      Buffer.add_char b '"';
      String.iter
        (function
          | '"' -> Buffer.add_string b "\\\""
          | '\\' -> Buffer.add_string b "\\\\"
          | '\n' -> Buffer.add_string b "\\n"
          | c when Char.code c < 0x20 -> Buffer.add_string b (Printf.sprintf "\\u%04x" (Char.code c))
          | c -> Buffer.add_char b c)
        s;
      Buffer.add_char b '"'
  | Arr l ->
      Buffer.add_char b '[';
      List.iteri
        (fun i x ->
          if i > 0 then Buffer.add_char b ',';
          write b x)
        l;
      Buffer.add_char b ']'
  | Obj l ->
      Buffer.add_char b '{';
      List.iteri
        (fun i (k, v) ->
          if i > 0 then Buffer.add_char b ',';
          write b (Str k);
          Buffer.add_char b ':';
          write b v)
        l;
      Buffer.add_char b '}'

let to_string j =
  let b = Buffer.create 65536 in
  write b j;
  Buffer.contents b

exception Parse_error of string

let parse s =
  let n = String.length s in
  let pos = ref 0 in
  let fail msg = raise (Parse_error (Printf.sprintf "%s at offset %d" msg !pos)) in
  let peek () = if !pos < n then s.[!pos] else '\000' in
  let rec ws () =
    if !pos < n && (match s.[!pos] with ' ' | '\n' | '\t' | '\r' -> true | _ -> false) then begin
      incr pos;
      ws ()
    end
  in
  let expect c =
    ws ();
    if peek () = c then incr pos else fail (Printf.sprintf "expected '%c'" c)
  in
  let lit word v =
    let k = String.length word in
    if !pos + k <= n && String.sub s !pos k = word then begin
      pos := !pos + k;
      v
    end
    else fail "bad literal"
  in
  let parse_string () =
    expect '"';
    let b = Buffer.create 16 in
    let rec loop () =
      if !pos >= n then fail "unterminated string";
      let c = s.[!pos] in
      incr pos;
      match c with
      | '"' -> ()
      | '\\' ->
          let e = s.[!pos] in
          incr pos;
          (match e with
          | 'n' -> Buffer.add_char b '\n'
          | 't' -> Buffer.add_char b '\t'
          | 'r' -> Buffer.add_char b '\r'
          | 'b' -> Buffer.add_char b '\b'
          | 'f' -> Buffer.add_char b '\012'
          | 'u' ->
              let code = int_of_string ("0x" ^ String.sub s !pos 4) in
              pos := !pos + 4;
              Buffer.add_char b (if code < 128 then Char.chr code else '?')
          | c -> Buffer.add_char b c);
          loop ()
      | c ->
          Buffer.add_char b c;
          loop ()
    in
    loop ();
    Buffer.contents b
  in
  let rec value () =
    ws ();
    match peek () with
    | '{' ->
        incr pos;
        ws ();
        if peek () = '}' then (incr pos; Obj [])
        else
          let rec fields acc =
            let k = parse_string () in
            expect ':';
            let v = value () in
            ws ();
            match peek () with
            | ',' -> incr pos; fields ((k, v) :: acc)
            | '}' -> incr pos; Obj (List.rev ((k, v) :: acc))
            | _ -> fail "bad object"
          in
          fields []
    | '[' ->
        incr pos;
        ws ();
        if peek () = ']' then (incr pos; Arr [])
        else
          let rec items acc =
            let v = value () in
            ws ();
            match peek () with
            | ',' -> incr pos; items (v :: acc)
            | ']' -> incr pos; Arr (List.rev (v :: acc))
            | _ -> fail "bad array"
          in
          items []
    | '"' -> Str (parse_string ())
    | 't' -> lit "true" (Bool true)
    | 'f' -> lit "false" (Bool false)
    | 'n' -> lit "null" Null
    | 'N' -> lit "NaN" (Num nan)
    | _ ->
        let start = !pos in
        while !pos < n && (match s.[!pos] with '0' .. '9' | '-' | '+' | '.' | 'e' | 'E' -> true | _ -> false) do
          incr pos
        done;
        if !pos = start then fail "unexpected character";
        Num (float_of_string (String.sub s start (!pos - start)))
  in
  value ()

let of_file path = parse (In_channel.with_open_bin path In_channel.input_all)
let member k = function Obj l -> List.assoc_opt k l | _ -> None
let to_list = function Some (Arr l) -> l | _ -> []
let to_num = function Num f -> f | _ -> nan
let to_str = function Some (Str s) -> s | _ -> ""
