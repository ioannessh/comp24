(** Copyright 2024-2025, David Akhmedov, Danil Parfyonov *)

(** SPDX-License-Identifier: LGPL-3.0-or-later *)

open AstLib.Ast

module CounterWriterMonad = struct
  type 'a cc = int -> ('a, string) Result.t * int * decl list

  let return (x : 'a) : 'a cc = fun s -> Ok x, s, []
  let fail (msg : string) : 'a cc = fun s -> Error msg, s, []

  let bind (m : 'a cc) (f : 'a -> 'b cc) : 'b cc =
    fun s ->
    match m s with
    | Ok x, s', d1 ->
      let y, s'', d2 = f x s' in
      y, s'', d1 @ d2
    | Error e, s', d1 -> Error e, s', d1
  ;;

  let ( >>= ) = bind
  let ( let* ) = bind

  let fresh_name (prefix : string) : string cc =
    fun s -> Ok (prefix ^ string_of_int s), s + 1, []
  ;;

  let tell (d : decl) : unit cc = fun s -> Ok (), s, [ d ]
end

open CounterWriterMonad
open Utils
open Common.Ident_utils

let cc_ll_prefix = "cc_ll_"

let rec pattern_to_string (pat : pattern_or_op) : string list =
  match pat with
  | POpPat p -> bound_vars_pattern p
  | POpOp s -> [ s ]
  | POrOpConstraint (p, _) -> pattern_to_string p
;;

let rec free_vars_expr (global_env : StringSet.t) (e : expr) : StringSet.t =
  match e with
  | EConstraint (e, _) -> free_vars_expr global_env e
  | EConst _ -> StringSet.empty
  | EId id ->
    (match id with
     | (IdentOfDefinable (IdentLetters s) | IdentOfDefinable (IdentOp s))
       when (not @@ String.starts_with ~prefix:cc_ll_prefix s)
            && (not @@ StringSet.contains global_env s) ->
       StringSet.singleton (ident_to_string id)
     | _ -> StringSet.empty)
  | EFun (pat, body) ->
    let bound =
      List.fold_left (fun s x -> StringSet.add s x) global_env (bound_vars_pattern pat)
    in
    free_vars_expr bound body
  | EApp (e1, e2) ->
    StringSet.union (free_vars_expr global_env e1) (free_vars_expr global_env e2)
  | EIf (e1, e2, e3) ->
    let fv_e1 = free_vars_expr global_env e1 in
    let fv_e2 = free_vars_expr global_env e2 in
    let fv_e3 = free_vars_expr global_env e3 in
    StringSet.union_all [ fv_e1; fv_e2; fv_e3 ]
  | EList (e1, e2) ->
    StringSet.union (free_vars_expr global_env e1) (free_vars_expr global_env e2)
  | ETuple (e1, e2, es) ->
    List.fold_left
      (fun acc et -> StringSet.union acc (free_vars_expr global_env et))
      (StringSet.union (free_vars_expr global_env e1) (free_vars_expr global_env e2))
      es
  | EClsr (decl, e) ->
    let bound_in_decl, fv_decl = free_vars_decl global_env decl in
    let fv_e = free_vars_expr global_env e in
    StringSet.union fv_decl (StringSet.diff fv_e bound_in_decl)
  | EMatch (e, br, brs) ->
    let brs = br :: brs in
    let fv_e = free_vars_expr global_env e in
    let free_vars_branch ((pat, expr) : branch) : StringSet.t =
      let bound =
        List.fold_left (fun s x -> StringSet.add s x) global_env (bound_vars_pattern pat)
      in
      StringSet.diff (free_vars_expr global_env expr) bound
    in
    let fv_brs =
      List.fold_left
        (fun acc b -> StringSet.union acc (free_vars_branch b))
        StringSet.empty
        brs
    in
    StringSet.union fv_e fv_brs

and free_vars_decl env (d : decl) : StringSet.t * StringSet.t =
  match d with
  | DLet (_, (pat_or_op, expr)) ->
    let bound =
      match pat_or_op with
      | POpPat (PId s) | POrOpConstraint (POpPat (PId s), _) -> StringSet.singleton s
      | _ -> StringSet.empty
    in
    bound, free_vars_expr (StringSet.union bound env) expr
  (* todo no test for this, praying it works 🙏🙏🙏*)
  | DLetMut (_, lb, lb2, lbs) ->
    let lbs = lb :: lb2 :: lbs in
    let all_pats =
      List.filter_map
        (fun (pat_or_op, _) ->
          match pat_or_op with
          | POpPat (PId s) | POrOpConstraint (POpPat (PId s), _) -> Some s
          | _ -> None)
        lbs
    in
    let bound = List.fold_left StringSet.add StringSet.empty all_pats in
    let free_in_lb (_, e) = free_vars_expr env e in
    let free_all =
      List.fold_left (fun s lb -> StringSet.union s (free_in_lb lb)) StringSet.empty lbs
    in
    bound, free_all
;;

let pattern_of_free_vars (fv : string list) : pattern =
  match fv with
  | [] -> PConst CUnit
  | [ x ] -> PId x
  | x :: y :: rest ->
    let p1 = PId x in
    let p2 = PId y in
    let rest_pats = List.map (fun v -> PId v) rest in
    PTuple (p1, p2, rest_pats)
;;

let rec get_efun_args_body local_env = function
  | EFun (pat, e) -> get_efun_args_body (bound_vars_pattern pat @ local_env) e
  | expr -> local_env, expr
;;

let rec replace_fun_body body = function
  | EFun (pat, e) -> EFun (pat, replace_fun_body body e)
  | _ -> body
;;

let rec subst_eid (e : expr) (subst : (string * expr) list) : expr =
  match e with
  | EConstraint (e, t) -> EConstraint (subst_eid e subst, t)
  | EConst _ -> e
  | EId id ->
    (match id with
     | IdentOfDefinable _ ->
       let name = ident_to_string id in
       (try List.assoc name subst with
        | Not_found -> e)
     | IdentOfBaseOp _ -> e)
  | EFun (pat, body) ->
    let bound = bound_vars_pattern pat in
    let subst' = List.filter (fun (x, _) -> not (List.mem x bound)) subst in
    EFun (pat, subst_eid body subst')
  | EApp (e1, e2) -> EApp (subst_eid e1 subst, subst_eid e2 subst)
  | EIf (e1, e2, e3) -> EIf (subst_eid e1 subst, subst_eid e2 subst, subst_eid e3 subst)
  | EList (e1, e2) -> EList (subst_eid e1 subst, subst_eid e2 subst)
  | ETuple (e1, e2, es) ->
    ETuple
      (subst_eid e1 subst, subst_eid e2 subst, List.map (fun e -> subst_eid e subst) es)
  | EClsr (decl, e) -> EClsr (substitute_decl decl subst, subst_eid e subst)
  | EMatch (e, br, brs) ->
    let substitute_branch ((pat, expr) : branch) (subst : (string * expr) list) : branch =
      let bound = bound_vars_pattern pat in
      let subst' = List.filter (fun (x, _) -> not (List.mem x bound)) subst in
      pat, subst_eid expr subst'
    in
    EMatch
      ( subst_eid e subst
      , substitute_branch br subst
      , List.map (fun b -> substitute_branch b subst) brs )

and substitute_decl (d : decl) (subst : (string * expr) list) : decl =
  let bound = function
    | POpPat (PId s) | POrOpConstraint (POpPat (PId s), _) -> [ s ]
    | _ -> []
  in
  match d with
  | DLet (rf, (pat_or_op, expr)) ->
    let subst' = List.filter (fun (x, _) -> not (List.mem x @@ bound pat_or_op)) subst in
    DLet (rf, (pat_or_op, subst_eid expr subst'))
  | DLetMut (rf, (pat_or_op, expr), (pat_or_op2, expr2), lbs) ->
    let patterns = pat_or_op :: pat_or_op2 :: List.map fst lbs in
    let bound = List.concat_map bound patterns in
    let subst' = List.filter (fun (x, _) -> not (List.mem x bound)) subst in
    DLetMut
      ( rf
      , (pat_or_op, subst_eid expr subst')
      , (pat_or_op2, subst_eid expr2 subst')
      , List.map (fun (p, e) -> p, subst_eid e subst') lbs )
;;

let rec closure_convert_expr
  (global_env : StringSet.t)
  (e : expr)
  (rec_name : string option)
  : expr cc
  =
  match e with
  | EConstraint (e, t) ->
    let* ce = closure_convert_expr global_env e rec_name in
    return @@ EConstraint (ce, t)
  | EConst _ | EId _ -> return e
  | EFun (_, _) as efun ->
    let local_env, body = get_efun_args_body [] efun in
    let new_env = StringSet.union global_env (StringSet.from_list local_env) in
    let* body' = closure_convert_expr global_env body rec_name in
    let fv = free_vars_expr new_env body' in
    let fv = StringSet.elements fv in
    let* f_name = fresh_name cc_ll_prefix in
    let body'' =
      match rec_name with
      | Some rec_name ->
        subst_eid body [ rec_name, EId (IdentOfDefinable (IdentLetters f_name)) ]
      | None -> body'
    in
    let new_fun =
      List.fold_left (fun acc x -> EFun (PId x, acc)) body'' (local_env @ fv)
    in
    let rf = if rec_name = None then Not_recursive else Recursive in
    let decl = DLet (rf, (POpPat (PId f_name), new_fun)) in
    let* () = tell decl in
    let new_fun_id = EId (IdentOfDefinable (IdentLetters f_name)) in
    let applied_fun =
      List.fold_right
        (fun x acc -> EApp (acc, EId (IdentOfDefinable (IdentLetters x))))
        fv
        new_fun_id
    in
    return @@ applied_fun
  | EApp (e1, e2) ->
    let* ce1 = closure_convert_expr global_env e1 rec_name in
    let* ce2 = closure_convert_expr global_env e2 rec_name in
    return (EApp (ce1, ce2))
  | EIf (e1, e2, e3) ->
    let* ce1 = closure_convert_expr global_env e1 rec_name in
    let* ce2 = closure_convert_expr global_env e2 rec_name in
    let* ce3 = closure_convert_expr global_env e3 rec_name in
    return (EIf (ce1, ce2, ce3))
  | EList (e1, e2) ->
    let* ce1 = closure_convert_expr global_env e1 rec_name in
    let* ce2 = closure_convert_expr global_env e2 rec_name in
    return (EList (ce1, ce2))
  | ETuple (e1, e2, es) ->
    let* ce1 = closure_convert_expr global_env e1 rec_name in
    let* ce2 = closure_convert_expr global_env e2 rec_name in
    let rec convert_list = function
      | [] -> return []
      | x :: xs ->
        let* cx = closure_convert_expr global_env x rec_name in
        let* cxs = convert_list xs in
        return (cx :: cxs)
    in
    let* ces = convert_list es in
    return (ETuple (ce1, ce2, ces))
  | EClsr (decl, e) ->
    let* cdecl = closure_convert_let_in global_env decl in
    let* ce = closure_convert_expr global_env e rec_name in
    return (EClsr (cdecl, ce))
    (* dirty hack for eliminating let a = expr in a *)
    (* (match cdecl, ce with
       | DLet (_, (POpPat (PId name), body)), EId _ ->
       let new_body = subst_eid ce [ name, body ] in
       return new_body
       (* let a = b in ...*)
       | DLet (_, (POpPat (PId name), (EId _ as body))), _ ->
       let new_body = subst_eid ce [ name, body ] in
       return new_body
       | _ -> return (EClsr (cdecl, ce))) *)
  | EMatch (e, br, brs) ->
    (* todo proper env *)
    let closure_convert_branch env (br : branch) : branch cc =
      let pat, expr = br in
      let* cexpr = closure_convert_expr env expr rec_name in
      return (pat, cexpr)
    in
    let* ce = closure_convert_expr global_env e rec_name in
    let* cbr = closure_convert_branch global_env br in
    let rec conv_branches env = function
      | [] -> return []
      | x :: xs ->
        let* cx = closure_convert_branch env x in
        let* cxs = conv_branches env xs in
        return (cx :: cxs)
    in
    let* cbrs = conv_branches global_env brs in
    return (EMatch (ce, cbr, cbrs))

and closure_convert_let_in global_env (d : decl) : decl cc =
  match d with
  | DLet (rf, (pat_or_op, expr)) ->
    let global_env =
      StringSet.union global_env
      @@ StringSet.from_list
      @@ if rf = Recursive then pattern_to_string pat_or_op else []
    in
    let* cexpr =
      closure_convert_expr
        global_env
        expr
        (if rf = Recursive then Some (List.hd (pattern_to_string pat_or_op)) else None)
    in
    return (DLet (Not_recursive, (pat_or_op, cexpr)))
    (* non rf flag probably not supported*)
  | DLetMut (rf, lb1, lb2, lbs) ->
    let process_lb (p, e) global_env =
      let rec_name = Some (List.hd (pattern_to_string p)) in
      let* cexpr = closure_convert_expr global_env e rec_name in
      return (p, cexpr)
    in
    let global_env =
      let patterns = lb1 :: lb2 :: lbs |> List.map fst in
      let patterns_to_string = List.concat_map pattern_to_string patterns in
      StringSet.union global_env (StringSet.from_list patterns_to_string)
    in
    let* lb1 = process_lb lb1 global_env in
    let* lb2 = process_lb lb2 global_env in
    let rec conv lbs global_env =
      match lbs with
      | [] -> return []
      | (pat, e) :: xs ->
        let* clb = process_lb (pat, e) global_env in
        let* clbs = conv xs global_env in
        return (clb :: clbs)
    in
    let* lbs = conv lbs global_env in
    return (DLetMut (rf, lb1, lb2, lbs))
;;

let common_convert_decl (global_env : StringSet.t) (_, (pat_or_op, expr))
  : (StringSet.t * let_body) cc
  =
  let _, body = get_efun_args_body (StringSet.elements global_env) expr in
  let* body' = closure_convert_expr global_env body None in
  let global_env =
    StringSet.union global_env (StringSet.from_list (pattern_to_string pat_or_op))
  in
  return (global_env, (pat_or_op, replace_fun_body body' expr))
;;

let closure_convert_decl (global_env : StringSet.t) (d : decl) : StringSet.t cc =
  match d with
  | DLet (rf, (pat_or_op, expr)) ->
    let* global_env, lb = common_convert_decl global_env (rf, (pat_or_op, expr)) in
    let* () = tell @@ DLet (rf, lb) in
    return global_env
  | DLetMut (rf, lb, lb2, lbs) ->
    let* global_env, clb = common_convert_decl global_env (Recursive, lb) in
    let* global_env, clb2 = common_convert_decl global_env (Recursive, lb2) in
    let rec conv lbs global_env =
      match lbs with
      | [] -> return []
      | lb :: xs ->
        let* global_env, clb = common_convert_decl global_env (Recursive, lb) in
        let* clbs = conv xs global_env in
        return (clb :: clbs)
    in
    let* clbs = conv lbs global_env in
    let* () = tell @@ DLetMut (rf, clb, clb2, clbs) in
    return global_env
;;

let closure_convert_decl_list (global_env : StringSet.t) (decls : decl list) =
  let rec helper global_env decls =
    match decls with
    | [] -> return global_env
    | d :: ds ->
      let* global_env = closure_convert_decl global_env d in
      helper global_env ds
  in
  helper global_env decls
;;

let closure_convert (prog : decl list) : (decl list, string) result =
  let global_env = StringSet.from_list Common.Stdlib.stdlib in
  let global_env, _, decls = closure_convert_decl_list global_env prog 0 in
  match global_env with
  | Ok _ -> Ok decls
  | Error s -> Error s
;;
