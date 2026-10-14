(* Long-only mean–variance optimisation with turnover cost, position and sector caps,
   and an optional volatility target:

     minimise  -a'w + (lambda/2) w'Sw + kappa * sum_i |w_i - w0_i| + mu * sum_s max(0, W_s - cap)^2
     s.t.      0 <= w_i <= ub_i,  lo <= sum_i w_i <= hi   (the remainder is cash)

   Solved by projected gradient with backtracking; |.| is smoothed. *)

type problem = {
  alpha : float array;
  sigma : float array array;
  w0 : float array;
  ub : float array;
  sector_of : int array;
  n_sectors : int;
  sector_cap : float;
  budget_lo : float;
  budget_hi : float;
  lambda : float;
  kappa : float;
}

let seps = 1e-5

let sector_sums p w =
  let s = Array.make p.n_sectors 0. in
  Array.iteri (fun i x -> s.(p.sector_of.(i)) <- s.(p.sector_of.(i)) +. x) w;
  s

let objective p mu w =
  let tc = ref 0. in
  Array.iteri (fun i x -> let d = x -. p.w0.(i) in tc := !tc +. sqrt ((d *. d) +. seps) -. sqrt seps) w;
  let pen = Array.fold_left (fun a s -> a +. Float.pow (Float.max 0. (s -. p.sector_cap)) 2.) 0. (sector_sums p w) in
  -.Linalg.dot p.alpha w +. (0.5 *. p.lambda *. Linalg.quad p.sigma w) +. (p.kappa *. !tc) +. (mu *. pen)

let gradient p mu w =
  let sw = Linalg.matvec p.sigma w in
  let excess = Array.map (fun s -> Float.max 0. (s -. p.sector_cap)) (sector_sums p w) in
  Array.mapi
    (fun i x ->
      let d = x -. p.w0.(i) in
      -.p.alpha.(i) +. (p.lambda *. sw.(i)) +. (p.kappa *. d /. sqrt ((d *. d) +. seps)) +. (2. *. mu *. excess.(p.sector_of.(i))))
    w

(* Euclidean projection onto {0 <= w <= ub, lo <= sum w <= hi} by bisection on the shift. *)
let project p v =
  let clipped tau = Array.mapi (fun i x -> Util.clip 0. p.ub.(i) (x -. tau)) v in
  let s0 = Util.sum (clipped 0.) in
  let target = if s0 > p.budget_hi then Some p.budget_hi else if s0 < p.budget_lo then Some (Float.min p.budget_lo (Util.sum p.ub)) else None in
  match target with
  | None -> clipped 0.
  | Some t ->
      let lo = ref (Array.fold_left Float.min infinity v -. Array.fold_left Float.max 0. p.ub -. 1.)
      and hi = ref (Array.fold_left Float.max neg_infinity v +. 1.) in
      for _ = 1 to 100 do
        let mid = 0.5 *. (!lo +. !hi) in
        if Util.sum (clipped mid) > t then lo := mid else hi := mid
      done;
      clipped (0.5 *. (!lo +. !hi))

let solve_fixed ?(max_iter = 5000) p =
  let rec outer mu w k =
    let w = ref w and step = ref 1.0 and it = ref 0 and conv = ref false in
    while (not !conv) && !it < max_iter do
      incr it;
      let g = gradient p mu !w and f0 = objective p mu !w in
      let rec attempt t tries =
        let cand = project p (Array.mapi (fun i x -> x -. (t *. g.(i))) !w) in
        let d = Array.mapi (fun i x -> x -. !w.(i)) cand in
        if objective p mu cand <= f0 +. Linalg.dot g d +. (Linalg.dot d d /. (2. *. t)) +. 1e-15 || tries > 60 then (cand, d, t)
        else attempt (t *. 0.5) (tries + 1)
      in
      let cand, d, t = attempt !step 0 in
      w := cand;
      step := Float.min 1e4 (t *. 1.5);
      if sqrt (Linalg.dot d d) < 1e-9 then conv := true
    done;
    let viol = Array.fold_left (fun a s -> Float.max a (s -. p.sector_cap)) 0. (sector_sums p !w) in
    if viol > 1e-4 && k < 6 then outer (mu *. 10.) !w (k + 1) else !w
  in
  outer 100. (project p (Array.copy p.w0)) 0

type result = { weights : float array; lambda_used : float; vol : float; hit_target : bool }

(* If the unconstrained-risk solution breaches the vol target, raise risk aversion
   (geometric bisection) until it is met; leftover budget goes to cash. *)
let solve p ~target_vol =
  let vol w = Risk.port_vol p.sigma w in
  let w = solve_fixed p in
  match target_vol with
  | Some tv when vol w > tv ->
      let rec grow lam k =
        let w = solve_fixed { p with lambda = lam } in
        if vol w <= tv || k >= 12 then (lam, w) else grow (lam *. 3.) (k + 1)
      in
      let hi, whi = grow (p.lambda *. 3.) 0 in
      if vol whi > tv then { weights = whi; lambda_used = hi; vol = vol whi; hit_target = false }
      else begin
        let lo = ref p.lambda and hi = ref hi and best = ref whi in
        for _ = 1 to 12 do
          let mid = sqrt (!lo *. !hi) in
          let wm = solve_fixed { p with lambda = mid } in
          if vol wm <= tv then (hi := mid; best := wm) else lo := mid
        done;
        { weights = !best; lambda_used = !hi; vol = vol !best; hit_target = true }
      end
  | _ -> { weights = w; lambda_used = p.lambda; vol = vol w; hit_target = true }
