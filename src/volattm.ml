(* Volatility forecasting: AurelPx/VolaTTM via a Python sidecar, with a Log-HAR
   fallback (the benchmark VolaTTM is evaluated against) and EWMA as last resort. *)
open Types

let horizon = Features_spec.horizon

(* rv5 covers the trading session only; portfolio risk is close-to-close. Scale the
   forecast by the trailing ratio of squared close-to-close returns to rv5. *)
let session_scale (bars : bar array) =
  let n = Array.length bars in
  let k = min 252 (n - 1) in
  if k < 20 then 1.0
  else
    let ms = Util.mean (Array.init k (fun j -> let i = n - k + j in Float.pow (log (bars.(i).c /. bars.(i - 1).c)) 2.)) in
    let rv = Util.mean (Array.init k (fun j -> bars.(n - k + j).rv5)) in
    Util.clip 0.5 4.0 (ms /. rv)

let trailing_vol (bars : bar array) =
  let n = Array.length bars in
  let k = min 22 (n - 1) in
  if k < 2 then nan
  else sqrt (252. *. Util.mean (Array.init k (fun j -> let i = n - k + j in Float.pow (log (bars.(i).c /. bars.(i - 1).c)) 2.)))

(* Log-HAR(1,5,22) fitted by OLS on up to 1000 sessions, iterated 22 steps ahead. *)
let har_path (x : float array) =
  let n = Array.length x in
  let avg (a : float array) i w = Util.mean (Array.sub a (i - w + 1) w) in
  let start = max 21 (n - 1001) in
  if n - start < 60 then None
  else begin
    let xtx = Array.make_matrix 4 4 0. and xty = Array.make 4 0. in
    for t = start to n - 2 do
      let row = [| 1.; x.(t); avg x t 5; avg x t 22 |] in
      for i = 0 to 3 do
        xty.(i) <- xty.(i) +. (row.(i) *. x.(t + 1));
        for j = 0 to 3 do xtx.(i).(j) <- xtx.(i).(j) +. (row.(i) *. row.(j)) done
      done
    done;
    for i = 0 to 3 do xtx.(i).(i) <- xtx.(i).(i) +. 1e-8 done;
    match Linalg.solve xtx xty with
    | None -> None
    | Some beta ->
        let hist = Array.append x (Array.make horizon 0.) in
        for h = 0 to horizon - 1 do
          let t = n - 1 + h in
          hist.(t + 1) <- Linalg.dot beta [| 1.; hist.(t); avg hist t 5; avg hist t 22 |]
        done;
        Some (Array.sub hist n horizon)
  end

let make ~sym ~source ~scale ~trailing (path : float array) =
  let v h = scale *. exp (Util.clip (-40.) 5. path.(h)) in
  let ann x = sqrt (252. *. x) in
  {
    vsym = sym;
    log_var_path = path;
    scale;
    vol_1d = ann (v 0);
    vol_5d = ann (v 4);
    vol_22d = ann (v (horizon - 1));
    vol_term = ann (Util.mean (Array.init horizon v));
    trailing_vol = trailing;
    source;
  }

(* Batch every eligible asset into one sidecar call: the model loads once. *)
let run_sidecar (cfg : Config.t) (batch : (string * float array array) list) =
  if batch = [] then Ok []
  else if not (Sys.file_exists cfg.sidecar) then Error ("sidecar script not found: " ^ cfg.sidecar)
  else begin
    let num x = Json.Num x in
    let asset (s, m) =
      Json.Obj [ ("symbol", Json.Str s); ("features", Json.Arr (Array.to_list (Array.map (fun r -> Json.Arr (Array.to_list (Array.map num r))) m))) ]
    in
    let req =
      Json.Obj
        [
          ("model", Json.Str cfg.model_id);
          ("revision", Json.Str cfg.model_revision);
          ("channels", Json.Arr (Array.to_list (Array.map (fun c -> Json.Str c) Features_spec.channels)));
          ("assets", Json.Arr (List.map asset batch));
        ]
    in
    let tin = Filename.temp_file "volattm_req" ".json" and tout = Filename.temp_file "volattm_resp" ".json" in
    Util.write_file tin (Json.to_string req);
    let cmd = String.concat " " (List.map Filename.quote [ cfg.python; cfg.sidecar; "--in"; tin; "--out"; tout ]) in
    let result =
      match Sys.command cmd with
      | 0 -> (
          match Json.of_file tout with
          | exception e -> Error ("unreadable sidecar output: " ^ Printexc.to_string e)
          | j when Json.member "error" j <> None -> Error (Json.to_str (Json.member "error" j))
          | j ->
              Ok
                (List.map
                   (fun f ->
                     ( Json.to_str (Json.member "symbol" f),
                       Array.of_list (List.map Json.to_num (Json.to_list (Json.member "log_variance_path" f))) ))
                   (Json.to_list (Json.member "forecasts" j))))
      | code -> Error (Printf.sprintf "sidecar exited with code %d" code)
    in
    (try Sys.remove tin; Sys.remove tout with Sys_error _ -> ());
    result
  end

let forecast_all (cfg : Config.t) (series : series list) : vol_forecast list =
  let eligible = if cfg.use_model then List.filter_map (fun s -> Option.map (fun w -> (s.sym, w)) (Features.window s.bars)) series else [] in
  let short = List.filter (fun s -> not (List.mem_assoc s.sym eligible)) series in
  if cfg.use_model && short <> [] then
    Printf.eprintf "[volattm] <%d valid sessions, using Log-HAR for: %s\n%!" Features_spec.context_length
      (String.concat ", " (List.map (fun s -> s.sym) short));
  let model_out =
    match run_sidecar cfg eligible with
    | Ok l -> l
    | Error e ->
        Printf.eprintf "[volattm] model unavailable (%s); falling back to Log-HAR\n%!" e;
        []
  in
  List.map
    (fun s ->
      let scale = session_scale s.bars and trailing = trailing_vol s.bars in
      let tag = if s.measured then "" else "*" in
      match List.assoc_opt s.sym model_out with
      | Some p when Array.length p >= horizon && Array.for_all Float.is_finite p ->
          make ~sym:s.sym ~source:("VolaTTM" ^ tag) ~scale ~trailing p
      | _ -> (
          match har_path (Array.map (fun b -> log (Float.max b.rv5 1e-16)) s.bars) with
          | Some p -> make ~sym:s.sym ~source:("Log-HAR" ^ tag) ~scale ~trailing p
          | None ->
              (* RiskMetrics EWMA on close-to-close returns; already close-to-close, so scale = 1 *)
              let v = ref nan in
              Array.iteri
                (fun i b ->
                  if i > 0 then
                    let r2 = Float.pow (log (b.c /. s.bars.(i - 1).c)) 2. in
                    v := if Float.is_nan !v then r2 else (0.94 *. !v) +. (0.06 *. r2))
                s.bars;
              let v = if Float.is_finite !v && !v > 0. then !v else 0.0004 in
              make ~sym:s.sym ~source:"EWMA" ~scale:1.0 ~trailing (Array.make horizon (log v))))
    series
