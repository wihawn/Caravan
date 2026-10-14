(* Loaders for price/realised-measure history, fundamentals, holdings and benchmark. *)
open Types

(* Garman–Klass open-to-close variance; used only when no intraday realised measures exist. *)
let gk_variance o h l c =
  let hl = log (h /. l) and co = log (c /. o) in
  Float.max 1e-10 ((0.5 *. hl *. hl) -. (((2. *. log 2.) -. 1.) *. co *. co))

let proxy_bar ~date ~o ~h ~l ~c ~volume ~trades =
  let v = gk_variance o h l c in
  { date; o; h; l; c; volume; trades; rv5 = v; rv5_ss = v; bv5 = v; rsn5 = 0.5 *. v; rk = v; rq5 = v *. v }

let load_series path sym =
  let csv = Util.read_csv path in
  let req n = Some (Util.col_exn csv path n) in
  let idate = Util.col_exn csv path "date" in
  let io = req "open" and ih = req "high" and il = req "low" and ic = req "close" in
  let opt = Util.col csv in
  let iv = opt "volume" and itr = opt "trades" in
  let realized_cols = List.map opt [ "rv5"; "rv5_ss"; "bv5"; "rsn5"; "rk"; "rq5" ] in
  let f = Util.float_field in
  let zero_nan x = if Float.is_nan x then 0. else x in
  let parsed =
    List.filter_map
      (fun r ->
        let date = Util.string_field r idate in
        let o = f r io and h = f r ih and l = f r il and c = f r ic in
        if date = "" || not (o > 0. && h > 0. && l > 0. && c > 0.) then None
        else
          let volume = zero_nan (f r iv) and trades = zero_nan (f r itr) in
          match List.map (f r) realized_cols with
          | [ rv5; rv5_ss; bv5; rsn5; rk; rq5 ]
            when rv5 > 0. && rv5_ss > 0. && bv5 > 0. && rsn5 >= 0. && rk > 0. && rq5 > 0. ->
              Some ({ date; o; h; l; c; volume; trades; rv5; rv5_ss; bv5; rsn5; rk; rq5 }, true)
          | _ -> Some (proxy_bar ~date ~o ~h ~l ~c ~volume ~trades, false))
      csv.rows
  in
  (* sort by ISO date, keep the last row for duplicated dates *)
  let sorted = List.stable_sort (fun (a, _) (b, _) -> compare a.date b.date) parsed in
  let dedup =
    List.fold_left
      (fun acc ((b, _) as x) -> match acc with (p, _) :: rest when p.date = b.date -> x :: rest | _ -> x :: acc)
      [] sorted
    |> List.rev |> Array.of_list
  in
  let recent = Util.sub_last dedup Features_spec.context_length in
  { sym; bars = Array.map fst dedup; measured = Array.length recent > 0 && Array.for_all snd recent }

let load_universe dir =
  if not (Sys.file_exists dir) then failwith ("daily data directory not found: " ^ dir);
  Sys.readdir dir |> Array.to_list
  |> List.filter (fun f -> Filename.check_suffix f ".csv")
  |> List.sort compare
  |> List.map (fun f -> load_series (Filename.concat dir f) (String.uppercase_ascii (Filename.chop_suffix f ".csv")))

let load_fundamentals path =
  let tbl = Hashtbl.create 64 in
  if Sys.file_exists path then begin
    let csv = Util.read_csv path in
    let isym = Util.col_exn csv path "symbol" and isec = Util.col csv "sector" in
    let g r name = Util.float_field r (Util.col csv name) in
    List.iter
      (fun r ->
        let fsym = String.uppercase_ascii (Util.string_field r isym) in
        let sector = match isec with Some i when Util.string_field r i <> "" -> Util.string_field r i | _ -> "Unknown" in
        Hashtbl.replace tbl fsym
          {
            fsym;
            sector;
            market_cap = g r "market_cap";
            net_income = g r "net_income";
            book_equity = g r "book_equity";
            free_cash_flow = g r "free_cash_flow";
            ebit = g r "ebit";
            enterprise_value = g r "enterprise_value";
            revenue = g r "revenue";
            revenue_prev = g r "revenue_prev";
            gross_profit = g r "gross_profit";
            total_assets = g r "total_assets";
            total_debt = g r "total_debt";
            operating_cash_flow = g r "operating_cash_flow";
          })
      csv.rows
  end
  else Printf.eprintf "[data] no fundamentals file at %s; value/quality/growth scores will be neutral\n%!" path;
  tbl

let load_holdings path =
  if not (Sys.file_exists path) then []
  else
    let csv = Util.read_csv path in
    let isym = Util.col_exn csv path "symbol" and ish = Some (Util.col_exn csv path "shares") in
    let icost = Util.col csv "cost_basis" in
    List.filter_map
      (fun r ->
        let hsym = String.uppercase_ascii (Util.string_field r isym) in
        let shares = Util.float_field r ish in
        if hsym = "" || not (Float.is_finite shares) || shares = 0. then None
        else Some { hsym; shares; cost = Util.float_field r icost })
      csv.rows

let load_benchmark path =
  let csv = Util.read_csv path in
  let id = Util.col_exn csv path "date" and ic = Some (Util.col_exn csv path "close") in
  let tbl = Hashtbl.create 1024 in
  List.iter (fun r -> let c = Util.float_field r ic in if c > 0. then Hashtbl.replace tbl (Util.string_field r id) c) csv.rows;
  tbl

let daily_header = "date,open,high,low,close,volume,trades,rv5,rv5_ss,bv5,rsn5,rk,rq5"

let write_series path bars =
  let b = Buffer.create (Array.length bars * 160) in
  Buffer.add_string b (daily_header ^ "\n");
  Array.iter
    (fun x ->
      Buffer.add_string b
        (Printf.sprintf "%s,%.4f,%.4f,%.4f,%.4f,%.0f,%.0f,%.6e,%.6e,%.6e,%.6e,%.6e,%.6e\n" x.date x.o x.h x.l x.c x.volume
           x.trades x.rv5 x.rv5_ss x.bv5 x.rsn5 x.rk x.rq5))
    bars;
  Util.write_file path (Buffer.contents b)
