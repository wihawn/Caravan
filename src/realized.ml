(* Build daily realised measures from 1-minute bars (the inputs VolaTTM needs).
   Definitions follow the standard estimators VOLARE publishes; small numerical
   differences from VOLARE's own pipeline (cleaning, kernel bandwidth) are expected. *)
open Types

let sq x = x *. x
let sum_sq r = Array.fold_left (fun a x -> a +. sq x) 0. r

(* log returns on a [step]-minute grid starting at [offset] *)
let grid_returns (p : float array) ~step ~offset =
  let n = Array.length p in
  let acc = ref [] in
  let j = ref (offset + step) in
  while !j < n do
    acc := log (p.(!j) /. p.(!j - step)) :: !acc;
    j := !j + step
  done;
  Array.of_list (List.rev !acc)

(* Realised kernel with Parzen weights. Bandwidth per Barndorff-Nielsen, Hansen, Lunde
   & Shephard (2009): H = c* xi^(4/5) n^(3/5), c* = 3.5134, where the noise-to-signal
   ratio xi^2 = omega^2 / IV uses omega^2 = RV_1min / 2n and IV ~ sparse RV. *)
let realized_kernel (r : float array) ~iv =
  let n = Array.length r in
  let omega2 = sum_sq r /. (2. *. float_of_int n) in
  let xi = sqrt (Float.max 1e-12 (omega2 /. Float.max iv 1e-16)) in
  let h = max 1 (int_of_float (Float.ceil (3.5134 *. (xi ** 0.8) *. (float_of_int n ** 0.6)))) in
  let parzen x = if x <= 0.5 then 1. -. (6. *. x *. x) +. (6. *. x *. x *. x) else if x <= 1. then 2. *. ((1. -. x) ** 3.) else 0. in
  let gamma k =
    let s = ref 0. in
    for j = k to n - 1 do s := !s +. (r.(j) *. r.(j - k)) done;
    !s
  in
  let acc = ref (gamma 0) in
  for k = 1 to min h (n - 1) do
    acc := !acc +. (2. *. parzen (float_of_int k /. float_of_int (h + 1)) *. gamma k)
  done;
  !acc

(* [p] = session open followed by each 1-minute close. *)
let day_measures (p : float array) =
  let floor_ x = Float.max x 1e-12 in
  let r5 = grid_returns p ~step:5 ~offset:0 in
  let m = Array.length r5 in
  let rv5 = sum_sq r5 in
  let rv5_ss =
    let tot = ref 0. in
    for o = 0 to 4 do
      let r = grid_returns p ~step:5 ~offset:o in
      if Array.length r > 0 then tot := !tot +. (sum_sq r *. float_of_int m /. float_of_int (Array.length r))
    done;
    !tot /. 5.
  in
  let bv5 =
    if m < 2 then rv5
    else begin
      let s = ref 0. in
      for i = 1 to m - 1 do s := !s +. (Float.abs r5.(i) *. Float.abs r5.(i - 1)) done;
      Float.pi /. 2. *. (float_of_int m /. float_of_int (m - 1)) *. !s
    end
  in
  let rsn5 = Array.fold_left (fun a x -> if x < 0. then a +. sq x else a) 0. r5 in
  let rq5 = float_of_int m /. 3. *. Array.fold_left (fun a x -> a +. (x ** 4.)) 0. r5 in
  let rk = Float.max (realized_kernel (grid_returns p ~step:1 ~offset:0) ~iv:rv5_ss) (0.1 *. rv5) in
  (floor_ rv5, floor_ rv5_ss, floor_ bv5, rsn5, floor_ rk, floor_ rq5)

(* Intraday CSV: date,time,open,high,low,close,volume[,trades], one row per minute. *)
let of_intraday_csv path : bar array =
  let csv = Util.read_csv path in
  let c n = Util.col_exn csv path n in
  let idate = c "date" and itime = c "time" in
  let io = Some (c "open") and ih = Some (c "high") and il = Some (c "low") and ic = Some (c "close") in
  let iv = Util.col csv "volume" and itr = Util.col csv "trades" in
  let rows =
    List.filter_map
      (fun r ->
        let cl = Util.float_field r ic in
        if cl > 0. then Some (Util.string_field r idate, Util.string_field r itime, r) else None)
      csv.rows
    |> List.sort (fun (d1, t1, _) (d2, t2, _) -> compare (d1, t1) (d2, t2))
  in
  let by_day = Hashtbl.create 512 and order = ref [] in
  List.iter
    (fun (d, _, r) ->
      match Hashtbl.find_opt by_day d with
      | Some l -> Hashtbl.replace by_day d (r :: l)
      | None -> Hashtbl.add by_day d [ r ]; order := d :: !order)
    rows;
  List.rev !order
  |> List.filter_map (fun date ->
         let rs = Array.of_list (List.rev (Hashtbl.find by_day date)) in
         if Array.length rs < 30 then None
         else
           let f = Util.float_field in
           let zero x = if Float.is_nan x then 0. else x in
           let closes = Array.map (fun r -> f r ic) rs in
           let o = let x = f rs.(0) io in if x > 0. then x else closes.(0) in
           let h = Array.fold_left (fun a r -> Float.max a (f r ih)) o rs |> Float.max (Array.fold_left Float.max 0. closes) in
           let l = Array.fold_left (fun a r -> let x = f r il in if x > 0. then Float.min a x else a) o rs |> Float.min (Array.fold_left Float.min infinity closes) in
           let volume = Array.fold_left (fun a r -> a +. zero (f r iv)) 0. rs in
           let trades = match itr with Some _ -> Array.fold_left (fun a r -> a +. zero (f r itr)) 0. rs | None -> float_of_int (Array.length rs) in
           let rv5, rv5_ss, bv5, rsn5, rk, rq5 = day_measures (Array.append [| o |] closes) in
           Some { date; o; h; l; c = closes.(Array.length closes - 1); volume; trades; rv5; rv5_ss; bv5; rsn5; rk; rq5 })
  |> Array.of_list
