(* Return tracking: position P&L, holdings backcast statistics and a NAV log for time-weighted returns. *)

type stats = {
  total_return : float;
  ann_return : float;
  ann_vol : float;
  sharpe : float;
  sortino : float;
  max_dd : float;
  hit_rate : float;
  n_days : int;
}

let stats ~rf (daily : float array) =
  let n = Array.length daily in
  let growth = Array.fold_left (fun a r -> a *. (1. +. r)) 1. daily in
  let ann_ret = if n > 0 then Float.pow growth (252. /. float_of_int n) -. 1. else nan in
  let vol = Util.std daily *. sqrt 252. in
  let downside = sqrt (Util.mean (Array.map (fun r -> Float.pow (Float.min r 0.) 2.) daily) *. 252.) in
  {
    total_return = growth -. 1.;
    ann_return = ann_ret;
    ann_vol = vol;
    sharpe = (ann_ret -. rf) /. vol;
    sortino = (ann_ret -. rf) /. downside;
    max_dd = Risk.max_drawdown daily;
    hit_rate = (if n > 0 then float_of_int (Array.length (Util.finite (Array.map (fun r -> if r > 0. then r else nan) daily))) /. float_of_int n else nan);
    n_days = n;
  }

(* NAV log rows: date,nav,flow. flow = external cash added (+) or withdrawn (-) that day. *)
let read_nav_log path =
  if not (Sys.file_exists path) then []
  else
    let csv = Util.read_csv path in
    let id = Util.col_exn csv path "date" and inav = Util.col csv "nav" and iflow = Util.col csv "flow" in
    List.filter_map
      (fun r ->
        let nav = Util.float_field r inav and flow = Util.float_field r iflow in
        if nav > 0. then Some (Util.string_field r id, nav, if Float.is_nan flow then 0. else flow) else None)
      csv.rows

(* Upsert today's NAV (one row per date). *)
let record_nav path ~date ~nav ~flow =
  let rows = List.filter (fun (d, _, _) -> d <> date) (read_nav_log path) @ [ (date, nav, flow) ] in
  let rows = List.sort (fun (a, _, _) (b, _, _) -> compare a b) rows in
  Util.mkdir_p (Filename.dirname path);
  Util.write_file path
    ("date,nav,flow\n" ^ String.concat "" (List.map (fun (d, n, f) -> Printf.sprintf "%s,%.2f,%.2f\n" d n f) rows))

(* Time-weighted return: chain (NAV_t - flow_t) / NAV_{t-1}. *)
let twr path =
  match read_nav_log path with
  | [] | [ _ ] -> None
  | (d0, n0, _) :: rest ->
      let g, _, last =
        List.fold_left (fun (g, prev, _) (d, n, f) -> (g *. ((n -. f) /. prev), n, d)) (1., n0, d0) rest
      in
      Some (g -. 1., d0, last, List.length rest + 1)
