(* Inference client: wire format, caching, error handling, look-ahead guard.
   Uses a stub transport, so no running service is needed. *)
open Fp
module IC = Inference_client

let health_json =
  {|{"ok":true,"device":"cpu","models":{"kronos":"ok","ttm":"ok","finbert":"ok","fingpt":"unavailable: no CUDA"},
     "kronos_model":"NeoQuasar/Kronos-small","ttm_branch":"512-48-ft-r2.1"}|}

(* Fake service: records every POST and answers like inference/app.py. *)
let stub ?(fail_ticker = "") () =
  let posts = ref [] in
  let post endpoint body =
    posts := (endpoint, body) :: !posts;
    let items = Yojson.Safe.(Util.member "items" (from_string body) |> Util.to_list) in
    let res =
      List.map
        (fun it ->
          let open Yojson.Safe.Util in
          let tk = member "ticker" it |> to_string and as_of = member "as_of" it |> to_string in
          if tk = fail_ticker then `Assoc [ ("ticker", `String tk); ("as_of", `String as_of); ("error", `String "boom") ]
          else
            match endpoint with
            | "/kronos" ->
                let closes = member "close" it |> to_list |> List.map to_number in
                let last = List.nth closes (List.length closes - 1) in
                `Assoc [ ("ticker", `String tk); ("as_of", `String as_of); ("forecast_return", `Float (last /. 1000.));
                         ("pred_close", `List [ `Float last ]); ("context_len", `Int (List.length closes));
                         ("seed", `Int 1); ("model", `String "NeoQuasar/Kronos-small"); ("seconds", `Float 0.1) ]
            | "/ttm_vol" ->
                `Assoc [ ("ticker", `String tk); ("as_of", `String as_of); ("log_var_path", `List [ `Float (-9.) ]);
                         ("ann_vol", `Float 0.2); ("branch", `String "512-48-ft-r2.1") ]
            | _ -> `Assoc [ ("ticker", `String tk); ("as_of", `String as_of); ("score", `Null); ("n", `Int 0) ])
        items
    in
    Ok (200, Yojson.Safe.to_string (`List res))
  in
  ({ IC.get = (fun _ -> Ok (200, health_json)); post }, posts)

let tmp_dir () =
  let d = Filename.concat (Filename.get_temp_dir_name ()) (Printf.sprintf "fp_cache_%d_%f" (Unix.getpid ()) (Unix.gettimeofday ())) in
  Util.mkdir_p d; d

let bars ?(start = 100.) n =
  Array.init n (fun i ->
      let c = start +. float_of_int i in
      { Types.date = Printf.sprintf "2024-%02d-%02d" (1 + (i / 28)) (1 + (i mod 28)); o = c; h = c +. 1.; l = c -. 1.; c;
        volume = 1000.; trades = 0.; rv5 = nan; rv5_ss = nan; bv5 = nan; rsn5 = nan; rk = nan; rq5 = nan })

let client ?fail_ticker () =
  let tr, posts = stub ?fail_ticker () in
  match IC.connect ~transport:tr ~base_url:"http://stub" ~cache_dir:(tmp_dir ()) () with
  | Ok c -> (c, posts)
  | Error e -> Alcotest.fail e

let test_wire_format () =
  let it = { IC.Kronos.ticker = "X"; as_of = "2024-01-02"; dates = [ "2024-01-02" ]; open_ = [ 1. ]; high = [ 2. ];
             low = [ 0.5 ]; close = [ 1.5 ]; volume = [ 10. ] } in
  let j = IC.Kronos.item_to_yojson it in
  let keys = match j with `Assoc kv -> List.map fst kv | _ -> [] in
  Alcotest.(check bool) "OCaml open_ is sent as \"open\"" true (List.mem "open" keys && not (List.mem "open_" keys));
  let r = {|{"ticker":"X","as_of":"d","forecast_return":0.05,"pred_close":[1.0],"context_len":3,"seed":1,
             "model":"m","seconds":4.2}|} in
  match IC.Kronos.result_of_yojson (Yojson.Safe.from_string r) with
  | Ok r -> Alcotest.(check (float 1e-12)) "decodes forecast_return, ignores extra fields" 0.05 r.forecast_return
  | Error e -> Alcotest.fail e

let test_cache_hit () =
  let c, posts = client () in
  let inputs = [ ("AAA", bars 30); ("BBB", bars ~start:200. 30) ] in
  let m1, e1 = IC.kronos_returns c ~as_of:"2024-12-31" inputs in
  Alcotest.(check int) "first call posts once (one batch)" 1 (List.length !posts);
  Alcotest.(check int) "no errors" 0 (List.length e1);
  let m2, _ = IC.kronos_returns c ~as_of:"2024-12-31" inputs in
  Alcotest.(check int) "second call is served from disk" 1 (List.length !posts);
  Alcotest.(check (list (pair string (float 0.)))) "identical outputs" (IC.Smap.bindings m1) (IC.Smap.bindings m2);
  Alcotest.(check int) "2 cache hits" 2 c.cache.hits

let test_cache_survives_restart () =
  let tr, posts = stub () in
  let dir = tmp_dir () in
  let mk () = Result.get_ok (IC.connect ~transport:tr ~base_url:"http://stub" ~cache_dir:dir ()) in
  ignore (IC.ttm (mk ()) ~as_of:"2024-12-31" [ ("AAA", Array.make 512 (-9.)) ]);
  ignore (IC.ttm (mk ()) ~as_of:"2024-12-31" [ ("AAA", Array.make 512 (-9.)) ]);
  Alcotest.(check int) "a new client reuses the on-disk cache" 1 (List.length !posts)

let test_stale_input_recomputed () =
  let c, posts = client () in
  ignore (IC.kronos_returns c ~as_of:"2024-12-31" [ ("AAA", bars 30) ]);
  (* same key (model, ticker, as_of) but revised history: must recompute, not reuse *)
  let m, _ = IC.kronos_returns c ~as_of:"2024-12-31" [ ("AAA", bars ~start:500. 30) ] in
  Alcotest.(check int) "posted again" 2 (List.length !posts);
  Alcotest.(check int) "counted as stale" 1 c.cache.stale;
  Alcotest.(check (float 1e-9)) "new value used" (529. /. 1000.) (IC.Smap.find "AAA" m)

let test_item_errors_not_cached () =
  let c, posts = client ~fail_ticker:"BAD" () in
  let m, errs = IC.kronos_returns c ~as_of:"2024-12-31" [ ("OK", bars 30); ("BAD", bars 30) ] in
  Alcotest.(check (list string)) "error reported per ticker" [ "BAD" ] (List.map fst errs);
  Alcotest.(check bool) "failed ticker absent from results" false (IC.Smap.mem "BAD" m);
  ignore (IC.kronos_returns c ~as_of:"2024-12-31" [ ("BAD", bars 30) ]);
  Alcotest.(check int) "failed item retried next time (not cached)" 2 (List.length !posts)

let test_lookahead_guard () =
  let c, _ = client () in
  Alcotest.check_raises "bar after as_of is rejected"
    (Invalid_argument "AAA: bar dated 2024-02-01 is after as_of 2024-01-31 (look-ahead)") (fun () ->
      ignore (IC.kronos_returns c ~as_of:"2024-01-31" [ ("AAA", bars 30) ]))

let test_context_truncated () =
  let c, posts = client () in
  ignore (IC.kronos_returns c ~as_of:"2099-12-31" [ ("AAA", bars 600) ]);
  let body = snd (List.hd !posts) in
  let n = Yojson.Safe.Util.(member "items" (Yojson.Safe.from_string body) |> to_list |> List.hd |> member "close" |> to_list |> List.length) in
  Alcotest.(check int) "Kronos context capped at 512 bars" 512 n

let test_unreachable () =
  let tr = { IC.get = (fun _ -> Error "Connection refused"); post = (fun _ _ -> Error "x") } in
  match IC.connect ~transport:tr ~base_url:"http://127.0.0.1:8766" ~cache_dir:"/tmp" () with
  | Ok _ -> Alcotest.fail "should not connect"
  | Error msg ->
      Alcotest.(check bool) "message tells the user how to start the service" true
        (Astring_contains.contains msg "make up-bg")

let tests =
  [ Alcotest.test_case "wire format" `Quick test_wire_format;
    Alcotest.test_case "cache hit avoids HTTP" `Quick test_cache_hit;
    Alcotest.test_case "cache persists across clients" `Quick test_cache_survives_restart;
    Alcotest.test_case "changed input is recomputed" `Quick test_stale_input_recomputed;
    Alcotest.test_case "per-item errors" `Quick test_item_errors_not_cached;
    Alcotest.test_case "look-ahead guard" `Quick test_lookahead_guard;
    Alcotest.test_case "context truncated to 512" `Quick test_context_truncated;
    Alcotest.test_case "clear error when service is down" `Quick test_unreachable ]
