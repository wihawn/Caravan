(* Typed client for the Python inference service (inference/app.py).

   The service runs models only. All inputs are built here, from data already
   truncated at [as_of]. Every model output is cached on disk at
   cache/<model-tag>/<ticker>/<as_of>.json with a hash of the exact input, so a
   backtest never recomputes a model output. If the input for a key changes (for
   example, revised price history), the entry is recomputed and counted as stale,
   never silently reused. *)

module Smap = Map.Make (String)

(* ---------- wire types ---------- *)

module Kronos = struct
  type item = {
    ticker : string;
    as_of : string;
    dates : string list;
    open_ : float list; [@key "open"]
    high : float list;
    low : float list;
    close : float list;
    volume : float list;
  }
  [@@deriving yojson]

  type request = {
    items : item list;
    pred_len : int;
    sample_count : int;
    temperature : float; [@key "T"]
    top_p : float;
    seed : int;
  }
  [@@deriving yojson]

  type result = {
    ticker : string;
    as_of : string;
    forecast_return : float;
    pred_close : float list;
    context_len : int;
    seed : int;
    model : string;
  }
  [@@deriving yojson { strict = false }]

  type params = { pred_len : int; sample_count : int; temperature : float; top_p : float; seed : int }

  let defaults = { pred_len = 21; sample_count = 8; temperature = 1.0; top_p = 0.9; seed = 17 }
  let max_context = 512
end

module Ttm = struct
  type item = { ticker : string; as_of : string; log_var : float list } [@@deriving yojson]
  type request = { items : item list } [@@deriving yojson]

  type result = { ticker : string; as_of : string; log_var_path : float list; ann_vol : float; branch : string }
  [@@deriving yojson { strict = false }]

  let context = 512
end

module Finbert = struct
  type item = { ticker : string; as_of : string; headlines : string list } [@@deriving yojson]
  type request = { items : item list } [@@deriving yojson]

  type result = { ticker : string; as_of : string; score : float option; [@default None] n : int }
  [@@deriving yojson { strict = false }]
end

type item_error = { ticker : string; as_of : string; error : string } [@@deriving yojson { strict = false }]

(* ---------- transport ---------- *)

type transport = {
  get : string -> (int * string, string) result;  (* path -> (status, body) *)
  post : string -> string -> (int * string, string) result;  (* path -> JSON body -> (status, body) *)
}

let curl_transport ?(timeout = 7200) base_url =
  let client = Ezcurl.make ~set_opts:(fun c -> Curl.set_timeout c timeout; Curl.set_connecttimeout c 5) () in
  let go ?content meth path =
    match Ezcurl.http ~client ~url:(base_url ^ path) ~meth ?content ~headers:[ ("Content-Type", "application/json") ] () with
    | Ok r -> Ok (r.Ezcurl.code, r.Ezcurl.body)
    | Error (_, msg) -> Error msg
  in
  { get = (fun p -> go Ezcurl.GET p); post = (fun p body -> go ~content:(`String body) (Ezcurl.POST []) p) }

(* ---------- disk cache ---------- *)

type cache = { dir : string; mutable hits : int; mutable misses : int; mutable stale : int }

let cache_path c ~model ~ticker ~as_of =
  List.fold_left Filename.concat c.dir [ model; ticker; as_of ^ ".json" ]

let input_hash j = Digest.to_hex (Digest.string (Yojson.Safe.to_string j))

let cache_find c ~model ~ticker ~as_of ~hash =
  let p = cache_path c ~model ~ticker ~as_of in
  if not (Sys.file_exists p) then None
  else
    match Yojson.Safe.from_file p with
    | `Assoc kv when List.assoc_opt "input_hash" kv = Some (`String hash) ->
        c.hits <- c.hits + 1;
        List.assoc_opt "output" kv
    | _ | (exception Yojson.Json_error _) ->
        c.stale <- c.stale + 1;
        None

let cache_store c ~model ~ticker ~as_of ~hash output =
  let p = cache_path c ~model ~ticker ~as_of in
  Util.mkdir_p (Filename.dirname p);
  let tmp = p ^ ".tmp" in
  Yojson.Safe.to_file tmp (`Assoc [ ("input_hash", `String hash); ("output", output) ]);
  Sys.rename tmp p

(* ---------- client ---------- *)

type health = {
  ok : bool;
  device : string;
  models : (string * string) list;
  kronos_model : string option;
  ttm_branch : string option;
}

type t = { transport : transport; cache : cache; health : health; base_url : string }

let parse_health body =
  let open Yojson.Safe.Util in
  let j = Yojson.Safe.from_string body in
  {
    ok = member "ok" j |> to_bool;
    device = member "device" j |> to_string;
    models = member "models" j |> to_assoc |> List.map (fun (k, v) -> (k, to_string v));
    kronos_model = member "kronos_model" j |> to_string_option;
    ttm_branch = member "ttm_branch" j |> to_string_option;
  }

let connect ?transport ~base_url ~cache_dir () =
  let transport = match transport with Some t -> t | None -> curl_transport base_url in
  let start = "start it with `make up-bg` (or `make up`) from the repository root" in
  match transport.get "/health" with
  | Error e -> Error (Printf.sprintf "inference service not reachable at %s (%s): %s" base_url e start)
  | Ok (200, body) -> (
      match parse_health body with
      | exception e -> Error ("unexpected /health response: " ^ Printexc.to_string e)
      | h when not h.ok ->
          Error
            (Printf.sprintf "inference service at %s is up but a required model failed to load: %s" base_url
               (String.concat "; " (List.map (fun (k, v) -> k ^ "=" ^ v) h.models)))
      | h -> Ok { transport; health = h; base_url; cache = { dir = cache_dir; hits = 0; misses = 0; stale = 0 } })
  | Ok (code, body) -> Error (Printf.sprintf "/health returned HTTP %d: %s" code body)

let model_status t name = Option.value (List.assoc_opt name t.health.models) ~default:"not reported"

(* Send uncached items in batches. Returns outputs by ticker plus per-item errors.
   Error items are never cached. *)
let run t ~model ~endpoint ~batch_size ~(wrap : Yojson.Safe.t list -> Yojson.Safe.t)
    (items : (string * string * Yojson.Safe.t) list) =
  let out = ref Smap.empty and errors = ref [] and todo = ref [] in
  List.iter
    (fun (ticker, as_of, j) ->
      let hash = input_hash j in
      match cache_find t.cache ~model ~ticker ~as_of ~hash with
      | Some o -> out := Smap.add ticker o !out
      | None -> todo := (ticker, as_of, j, hash) :: !todo)
    items;
  let rec chunks acc = function
    | [] -> List.rev acc
    | l ->
        let n = min batch_size (List.length l) in
        chunks (List.filteri (fun i _ -> i < n) l :: acc) (List.filteri (fun i _ -> i >= n) l)
  in
  List.iter
    (fun batch ->
      let body = Yojson.Safe.to_string (wrap (List.map (fun (_, _, j, _) -> j) batch)) in
      match t.transport.post endpoint body with
      | Error e -> List.iter (fun (tk, _, _, _) -> errors := (tk, "transport: " ^ e) :: !errors) batch
      | Ok (200, resp) ->
          let results = match Yojson.Safe.from_string resp with `List l -> l | _ -> [] in
          if List.length results <> List.length batch then
            List.iter (fun (tk, _, _, _) -> errors := (tk, "malformed batch response") :: !errors) batch
          else
            List.iter2
              (fun (tk, as_of, _, hash) r ->
                match item_error_of_yojson r with
                | Ok e when e.error <> "" -> errors := (tk, e.error) :: !errors
                | _ ->
                    t.cache.misses <- t.cache.misses + 1;
                    cache_store t.cache ~model ~ticker:tk ~as_of ~hash r;
                    out := Smap.add tk r !out)
              batch results
      | Ok (code, resp) ->
          let detail = try Yojson.Safe.(Util.member "detail" (from_string resp) |> to_string) with _ -> resp in
          List.iter (fun (tk, _, _, _) -> errors := (tk, Printf.sprintf "HTTP %d: %s" code detail) :: !errors) batch)
    (chunks [] (List.rev !todo));
  (!out, List.rev !errors)

let decode_map of_yojson m =
  Smap.filter_map (fun _ j -> match of_yojson j with Ok r -> Some r | Error _ -> None) m

(* Inputs must already be truncated at [as_of]. This is a defensive re-check; the
   structural guarantee comes from the point-in-time views (Pit). *)
let check_as_of ~as_of ticker (dates : string array) =
  Array.iter
    (fun d -> if d > as_of then invalid_arg (Printf.sprintf "%s: bar dated %s is after as_of %s (look-ahead)" ticker d as_of))
    dates

(* ---------- per-model functions ---------- *)

let kronos_tag t (p : Kronos.params) =
  let variant = match t.health.kronos_model with Some m -> Filename.basename m | None -> "unknown" in
  Printf.sprintf "kronos-%s_pl%d_s%d_T%g_p%g_seed%d" variant p.pred_len p.sample_count p.temperature p.top_p p.seed

let kronos ?(params = Kronos.defaults) ?(batch_size = 8) t ~as_of (inputs : (string * Types.bar array) list) =
  let items =
    List.map
      (fun (ticker, (bars : Types.bar array)) ->
        let bars = Util.sub_last bars Kronos.max_context in
        check_as_of ~as_of ticker (Array.map (fun (b : Types.bar) -> b.date) bars);
        let col f = Array.to_list (Array.map f bars) in
        let it =
          { Kronos.ticker; as_of; dates = col (fun b -> b.date); open_ = col (fun b -> b.o); high = col (fun b -> b.h);
            low = col (fun b -> b.l); close = col (fun b -> b.c); volume = col (fun b -> b.volume) }
        in
        (ticker, as_of, Kronos.item_to_yojson it))
      inputs
  in
  let wrap js =
    `Assoc
      [ ("items", `List js); ("pred_len", `Int params.pred_len); ("sample_count", `Int params.sample_count);
        ("T", `Float params.temperature); ("top_p", `Float params.top_p); ("seed", `Int params.seed) ]
  in
  let raw, errors = run t ~model:(kronos_tag t params) ~endpoint:"/kronos" ~batch_size ~wrap items in
  (decode_map Kronos.result_of_yojson raw, errors)

let kronos_returns ?params t ~as_of inputs =
  let m, errors = kronos ?params t ~as_of inputs in
  (Smap.map (fun (r : Kronos.result) -> r.forecast_return) m, errors)

let ttm_tag t = "ttm-" ^ Option.value t.health.ttm_branch ~default:"unknown"

(* [inputs]: per ticker, the last 512 daily log-variance values up to [as_of]. *)
let ttm ?(batch_size = 64) t ~as_of (inputs : (string * float array) list) =
  let items =
    List.map
      (fun (ticker, lv) ->
        if Array.length lv <> Ttm.context then
          invalid_arg (Printf.sprintf "%s: TTM needs %d values, got %d" ticker Ttm.context (Array.length lv));
        (ticker, as_of, Ttm.item_to_yojson { Ttm.ticker; as_of; log_var = Array.to_list lv }))
      inputs
  in
  let raw, errors = run t ~model:(ttm_tag t) ~endpoint:"/ttm_vol" ~batch_size ~wrap:(fun js -> `Assoc [ ("items", `List js) ]) items in
  (decode_map Ttm.result_of_yojson raw, errors)

(* Live only. Tickers with no headlines map to None (missing), not 0. *)
let finbert ?(batch_size = 16) t ~as_of (inputs : (string * string list) list) =
  let items =
    List.map (fun (ticker, headlines) -> (ticker, as_of, Finbert.item_to_yojson { Finbert.ticker; as_of; headlines })) inputs
  in
  let raw, errors =
    run t ~model:"finbert-0bc2ac1" ~endpoint:"/finbert" ~batch_size ~wrap:(fun js -> `Assoc [ ("items", `List js) ]) items
  in
  (decode_map Finbert.result_of_yojson raw |> Smap.filter_map (fun _ (r : Finbert.result) -> r.score), errors)

let cache_summary t =
  Printf.sprintf "cache: %d hits, %d computed, %d stale entries recomputed (%s)" t.cache.hits t.cache.misses t.cache.stale
    t.cache.dir
