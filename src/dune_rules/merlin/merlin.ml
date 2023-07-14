open Import

let remove_extension file =
  let dir = Path.Build.parent_exn file in
  let basename, _ext = String.lsplit2_exn (Path.Build.basename file) ~on:'.' in
  Path.Build.relative dir basename

module Processed = struct
  (* The actual content of the merlin file as built by the [Unprocessed.process]
     function from the unprocessed info gathered through [gen_rules]. The first
     three fields map directly to Merlin's B, S and FLG directives and the last
     one represents a list of preprocessors described by a preprocessing flag
     and its arguments. *)

  module Pp_kind = struct
    type t =
      | Pp
      | Ppx

    let to_dyn =
      let open Dyn in
      function
      | Pp -> variant "Pp" []
      | Ppx -> variant "Ppx" []

    let to_flag = function
      | Pp -> "-pp"
      | Ppx -> "-ppx"
  end

  type pp_flag =
    { flag : Pp_kind.t
    ; args : string
    }

  let dyn_of_pp_flag { flag; args } =
    let open Dyn in
    record [ ("flag", Pp_kind.to_dyn flag); ("args", string args) ]

  let pp_kind x = x.flag

  let pp_args x = x.args

  (* Most of the configuration is shared across a same lib/exe... *)
  type config =
    { stdlib_dir : Path.t option
    ; obj_dirs : Path.Set.t
    ; src_dirs : Path.Set.t
    ; flags : string list
    ; extensions : string option Ml_kind.Dict.t list
    ; melc_flags : string list
    }

  let dyn_of_config
      { stdlib_dir; obj_dirs; src_dirs; flags; extensions; melc_flags } =
    let open Dyn in
    record
      [ ("stdlib_dir", option Path.to_dyn stdlib_dir)
      ; ("obj_dirs", Path.Set.to_dyn obj_dirs)
      ; ("src_dirs", Path.Set.to_dyn src_dirs)
      ; ("flags", list string flags)
      ; ("extensions", list (Ml_kind.Dict.to_dyn (Dyn.option string)) extensions)
      ; ("melc_flags", list string melc_flags)
      ]

  type module_config =
    { opens : Module_name.t list
    ; module_ : Module.t
    }

  let dyn_of_module_config { opens; module_ } =
    let open Dyn in
    record
      [ ("opens", list Module_name.to_dyn opens)
      ; ("module_", Module.to_dyn module_)
      ]

  (* ...but modules can have different preprocessing specifications*)
  type t =
    { config : config
    ; per_module_config : module_config Path.Build.Map.t
    ; pp_config : pp_flag option Module_name.Per_item.t
    }

  let to_dyn { config; per_module_config; pp_config } =
    let open Dyn in
    record
      [ ("config", dyn_of_config config)
      ; ( "per_module_config"
        , Path.Build.Map.to_dyn dyn_of_module_config per_module_config )
      ; ( "pp_config"
        , Module_name.Per_item.to_dyn (option dyn_of_pp_flag) pp_config )
      ]

  module D = struct
    type nonrec t = t

    let name = "merlin-conf"

    let version = 4

    let to_dyn _ = Dyn.String "Use [dune ocaml dump-dot-merlin] instead"

    let test_example () =
      { config =
          { stdlib_dir = None
          ; obj_dirs = Path.Set.empty
          ; src_dirs = Path.Set.empty
          ; flags = [ "-x" ]
          ; extensions = [ { Ml_kind.Dict.intf = None; impl = Some "ext" } ]
          ; melc_flags = [ "-y" ]
          }
      ; per_module_config = Path.Build.Map.empty
      ; pp_config =
          (match
             Module_name.Per_item.of_mapping
               [ ( [ Module_name.of_string "Test" ]
                 , Some { flag = Ppx; args = "-x" } )
               ]
               ~default:None
           with
          | Ok s -> s
          | Error (_, _, _) -> assert false)
      }
  end

  module Persist = Dune_util.Persistent.Make (D)

  let load_file f =
    (* Failing to load the file at that point means that the configuration file
       has been written by a version of Dune in which the [Merlin.Processed.t]
       type is different from the one in the current version. *)
    match Persist.load f with
    | Some s -> Ok s
    | None ->
      Error
        "The current Merlin configuration has been generated by another, \
         incompatible, version of Dune. Please rebuild the project. (Using the \
         same version of Dune as the one running the `ocaml-merlin` server.)"

  let serialize_path = Path.to_absolute_filename

  let get_ext { Ml_kind.Dict.impl; intf } =
    match (impl, intf) with
    | Some impl, Some intf -> Some (impl, intf)
    | Some impl, None -> Some (impl, impl)
    | None, Some intf -> Some (intf, intf)
    | None, None -> None

  let to_sexp ~opens ~pp
      { stdlib_dir; obj_dirs; src_dirs; flags; extensions; melc_flags } =
    let make_directive tag value = Sexp.List [ Atom tag; value ] in
    let make_directive_of_path tag path =
      make_directive tag (Sexp.Atom (serialize_path path))
    in
    let stdlib_dir =
      match stdlib_dir with
      | None -> []
      | Some stdlib_dir -> [ make_directive_of_path "STDLIB" stdlib_dir ]
    in
    let exclude_query_dir = [ Sexp.List [ Atom "EXCLUDE_QUERY_DIR" ] ] in
    let obj_dirs =
      Path.Set.to_list_map obj_dirs ~f:(make_directive_of_path "B")
    in
    let src_dirs =
      Path.Set.to_list_map src_dirs ~f:(make_directive_of_path "S")
    in
    let flags =
      let flags =
        match flags with
        | [] -> []
        | flags ->
          [ make_directive "FLG"
              (Sexp.List (List.map ~f:(fun s -> Sexp.Atom s) flags))
          ]
      in
      let flags =
        match melc_flags with
        | [] -> flags
        | melc_flags ->
          make_directive "FLG"
            (Sexp.List (List.map ~f:(fun s -> Sexp.Atom s) melc_flags))
          :: flags
      in
      let flags =
        match pp with
        | None -> flags
        | Some { flag; args } ->
          make_directive "FLG"
            (Sexp.List [ Atom (Pp_kind.to_flag flag); Atom args ])
          :: flags
      in
      match opens with
      | [] -> flags
      | opens ->
        make_directive "FLG"
          (Sexp.List
             (List.concat_map opens ~f:(fun name ->
                  [ Sexp.Atom "-open"; Atom (Module_name.to_string name) ])))
        :: flags
    in
    let suffixes =
      List.filter_map extensions ~f:(fun x ->
          let open Option.O in
          let+ impl, intf = get_ext x in
          make_directive "SUFFIX" (Sexp.Atom (Printf.sprintf "%s %s" impl intf)))
    in
    Sexp.List
      (List.concat
         [ stdlib_dir; exclude_query_dir; obj_dirs; src_dirs; flags; suffixes ])

  let quote_for_dot_merlin s =
    let s =
      if Sys.win32 then
        (* We need this hack because merlin unescapes backslashes (except when
           protected by single quotes). It is only a problem on windows because
           Filename.quote is using double quotes. *)
        String.escape_only '\\' s
      else s
    in
    if String.need_quoting s then Filename.quote s else s

  let to_dot_merlin stdlib_dir pp_configs flags obj_dirs src_dirs extensions =
    let b = Buffer.create 256 in
    let printf = Printf.bprintf b in
    let print = Buffer.add_string b in
    print "EXCLUDE_QUERY_DIR\n";
    Option.iter stdlib_dir ~f:(fun stdlib_dir ->
        printf "STDLIB %s\n" (serialize_path stdlib_dir));
    Path.Set.iter obj_dirs ~f:(fun p -> printf "B %s\n" (serialize_path p));
    Path.Set.iter src_dirs ~f:(fun p -> printf "S %s\n" (serialize_path p));
    List.iter extensions ~f:(fun x ->
        Option.iter (get_ext x) ~f:(fun (impl, intf) ->
            printf "SUFFIX %s" (Printf.sprintf "%s %s" impl intf)));
    (* We print all FLG directives as comments *)
    List.iter pp_configs
      ~f:
        (Module_name.Per_item.fold ~init:() ~f:(fun pp () ->
             Option.iter pp ~f:(fun { flag; args } ->
                 printf "# FLG %s\n"
                   (Pp_kind.to_flag flag ^ " " ^ quote_for_dot_merlin args))));
    List.iter flags ~f:(fun flags ->
        match flags with
        | [] -> ()
        | flags ->
          print "# FLG";
          List.iter flags ~f:(fun f -> printf " %s" (quote_for_dot_merlin f));
          print "\n");
    Buffer.contents b

  let get { per_module_config; pp_config; config } ~file =
    (* We only match the first part of the filename : foo.ml -> foo foo.cppo.ml
       -> foo *)
    let open Option.O in
    let+ { module_; opens } =
      let find file =
        let file_without_ext = remove_extension file in
        Path.Build.Map.find per_module_config file_without_ext
      in
      match find file with
      | Some _ as s -> s
      | None -> Copy_line_directive.DB.follow_while file ~f:find
    in
    let pp = Module_name.Per_item.get pp_config (Module.name module_) in
    to_sexp ~opens ~pp config

  let print_file path =
    match load_file path with
    | Error msg -> Printf.eprintf "%s\n" msg
    | Ok { per_module_config; pp_config; config } ->
      let pp_one { module_; opens } =
        let open Pp.O in
        let name = Module.name module_ in
        let pp = Module_name.Per_item.get pp_config name in
        let sexp = to_sexp ~opens ~pp config in
        Pp.vbox (Pp.text (Module_name.to_string name))
        ++ Pp.newline
        ++ Pp.vbox (Sexp.pp sexp)
      in
      let pp =
        Path.Build.Map.values per_module_config
        |> Pp.concat_map ~sep:Pp.cut ~f:pp_one
        |> Pp.vbox
      in
      Format.printf "%a@." Pp.to_fmt pp

  let print_generic_dot_merlin paths =
    match Result.List.map paths ~f:load_file with
    | Error msg -> Printf.eprintf "%s\n" msg
    | Ok [] -> Printf.eprintf "No merlin configuration found.\n"
    | Ok (init :: tl) ->
      let pp_configs, obj_dirs, src_dirs, flags, extensions, melc_flags =
        (* We merge what is easy to merge and ignore the rest *)
        List.fold_left tl
          ~init:
            ( [ init.pp_config ]
            , init.config.obj_dirs
            , init.config.src_dirs
            , [ init.config.flags ]
            , init.config.extensions
            , init.config.melc_flags )
          ~f:(fun
               (acc_pp, acc_obj, acc_src, acc_flags, acc_ext, acc_melc_flags)
               { per_module_config = _
               ; pp_config
               ; config =
                   { stdlib_dir = _
                   ; obj_dirs
                   ; src_dirs
                   ; flags
                   ; extensions
                   ; melc_flags
                   }
               }
             ->
            ( pp_config :: acc_pp
            , Path.Set.union acc_obj obj_dirs
            , Path.Set.union acc_src src_dirs
            , flags :: acc_flags
            , extensions @ acc_ext
            , match acc_melc_flags with
              | [] -> melc_flags
              | acc_melc_flags -> acc_melc_flags ))
      in
      let flags =
        match melc_flags with
        | [] -> flags
        | melc -> melc :: flags
      in
      Printf.printf "%s\n"
        (to_dot_merlin init.config.stdlib_dir pp_configs flags obj_dirs src_dirs
           extensions)
end

let obj_dir_of_lib kind mode obj_dir =
  (match (kind, mode) with
  | `Private, Lib_mode.Ocaml _ -> Obj_dir.byte_dir
  | `Private, Melange -> Obj_dir.melange_dir
  | `Public, Ocaml _ -> Obj_dir.public_cmi_ocaml_dir
  | `Public, Melange -> Obj_dir.public_cmi_melange_dir)
    obj_dir

module Unprocessed = struct
  (* We store separate information for each "module". These information do not
     reflect the actual content of the Merlin configuration yet but are needed
     for it's elaboration via the function [process : Unprocessed.t ... ->
     Processed.t] *)
  type config =
    { stdlib_dir : Path.t
    ; requires : Lib.Set.t
    ; flags : string list Action_builder.t
    ; preprocess :
        Preprocess.Without_instrumentation.t Preprocess.t Module_name.Per_item.t
    ; libname : Lib_name.Local.t option
    ; source_dirs : Path.Source.Set.t
    ; objs_dirs : Path.Set.t
    ; extensions : string option Ml_kind.Dict.t list
    ; mode : Lib_mode.t
    }

  type t =
    { ident : Merlin_ident.t
    ; config : config
    ; modules : Modules.t
    }

  let make ~requires ~stdlib_dir ~flags ~preprocess ~libname ~source_dirs
      ~modules ~obj_dir ~dialects ~ident ~modes =
    (* Merlin shouldn't cause the build to fail, so we just ignore errors *)
    let mode =
      match modes with
      | `Exe -> Lib_mode.Ocaml Byte
      | `Melange_emit -> Melange
      | `Lib (m : Lib_mode.Map.Set.t) -> Lib_mode.Map.Set.for_merlin m
    in
    let requires =
      match Resolve.peek requires with
      | Ok l -> Lib.Set.of_list l
      | Error () -> Lib.Set.empty
    in
    let objs_dirs =
      Path.Set.singleton
      @@ obj_dir_of_lib `Private mode (Obj_dir.of_local obj_dir)
    in
    let flags = Ocaml_flags.get flags mode in
    let extensions = Dialect.DB.extensions_for_merlin dialects in
    let config =
      { stdlib_dir
      ; mode
      ; requires
      ; flags
      ; preprocess
      ; libname
      ; source_dirs
      ; objs_dirs
      ; extensions
      }
    in
    { ident; config; modules }

  let encode_command =
    let quote_if_needed s =
      if String.need_quoting s then Filename.quote s else s
    in
    fun ~bin ~args ->
      Path.to_absolute_filename bin :: args
      |> List.map ~f:quote_if_needed
      |> String.concat ~sep:" "

  let pp_flag_of_action ~expander ~loc ~action :
      Processed.pp_flag option Action_builder.t =
    match (action : Dune_lang.Action.t) with
    | Run (exe, args) -> (
      match
        let open Option.O in
        let* args, input_file = List.destruct_last args in
        if String_with_vars.is_pform input_file (Var Input_file) then Some args
        else None
      with
      | None -> Action_builder.return None
      | Some args ->
        let action =
          let action = Action_unexpanded.Run (exe, args) in
          let chdir = (Expander.context expander).build_dir in
          Action_unexpanded.expand_no_targets ~loc ~expander ~deps:[] ~chdir
            ~what:"preprocessing actions" action
        in
        let pp_of_action exe args =
          match exe with
          | Error _ -> None
          | Ok bin ->
            let args = encode_command ~bin ~args in
            Some { Processed.flag = Processed.Pp_kind.Pp; args }
        in
        Action_builder.map action ~f:(fun act ->
            match act.action with
            | Run (exe, args) -> pp_of_action exe args
            | Chdir (_, Run (exe, args)) -> pp_of_action exe args
            | Chdir (_, Chdir (_, Run (exe, args))) -> pp_of_action exe args
            | _ -> None))
    | _ -> Action_builder.return None

  let pp_flags sctx ~expander lib_name preprocess :
      Processed.pp_flag option Action_builder.t =
    match
      Preprocess.remove_future_syntax preprocess ~for_:Merlin
        (Super_context.context sctx).ocaml.version
    with
    | Action (loc, (action : Dune_lang.Action.t)) ->
      pp_flag_of_action ~expander ~loc ~action
    | No_preprocessing -> Action_builder.return None
    | Pps { loc; pps; flags; staged = _ } ->
      let open Action_builder.O in
      let+ exe, flags =
        let scope = Expander.scope expander in
        Preprocessing.get_ppx_driver sctx ~loc ~expander ~lib_name ~flags ~scope
          pps
      in
      let args =
        encode_command ~bin:(Path.build exe) ~args:("--as-ppx" :: flags)
      in
      Some { Processed.flag = Processed.Pp_kind.Ppx; args }

  let src_dirs sctx lib =
    let info = Lib.info lib in
    match
      let obj_dir = Lib_info.obj_dir info in
      Path.is_managed (Obj_dir.byte_dir obj_dir)
    with
    | false -> Memo.return (Path.Set.singleton (Lib_info.src_dir info))
    | true ->
      let open Memo.O in
      let+ modules = Dir_contents.modules_of_lib sctx lib in
      let modules = Option.value_exn modules in
      Path.Set.map ~f:Path.drop_optional_build_context
        (Modules.source_dirs modules)

  module Per_item_action_builder =
    Module_name.Per_item.Make_monad_traversals (Action_builder)

  let pp_config t sctx ~expander =
    Per_item_action_builder.map t.config.preprocess
      ~f:(pp_flags sctx ~expander t.config.libname)

  let process
      ({ modules
       ; ident = _
       ; config =
           { stdlib_dir
           ; extensions
           ; flags
           ; objs_dirs
           ; source_dirs
           ; requires
           ; preprocess = _
           ; libname = _
           ; mode
           }
       } as t) sctx ~dir ~more_src_dirs ~expander =
    let open Action_builder.O in
    let+ config =
      let* stdlib_dir =
        Action_builder.of_memo
        @@
        match t.config.mode with
        | Ocaml _ -> Memo.return (Some stdlib_dir)
        | Melange -> (
          let open Memo.O in
          let+ dirs = Melange_binary.where sctx ~loc:None ~dir in
          match dirs with
          | [] -> None
          | stdlib_dir :: _ -> Some stdlib_dir)
      in
      let* requires =
        match t.config.mode with
        | Ocaml _ -> Action_builder.return requires
        | Melange ->
          Action_builder.of_memo
            (let open Memo.O in
             let scope = Expander.scope expander in
             let libs = Scope.libs scope in
             Lib.DB.find libs (Lib_name.of_string "melange") >>= function
             | Some lib ->
               let+ libs =
                 let linking =
                   Dune_project.implicit_transitive_deps (Scope.project scope)
                 in
                 Lib.closure [ lib ] ~linking |> Resolve.Memo.peek >>| function
                 | Ok libs -> libs
                 | Error _ -> []
               in
               Lib.Set.union requires (Lib.Set.of_list libs)
             | None -> Memo.return requires)
      in
      let* flags = flags
      and* src_dirs, obj_dirs =
        Action_builder.of_memo
          (let open Memo.O in
           Memo.parallel_map (Lib.Set.to_list requires) ~f:(fun lib ->
               let+ dirs = src_dirs sctx lib in
               (lib, dirs))
           >>| List.fold_left
                 ~init:(Path.set_of_source_paths source_dirs, objs_dirs)
                 ~f:(fun (src_dirs, obj_dirs) (lib, more_src_dirs) ->
                   ( Path.Set.union src_dirs more_src_dirs
                   , let public_cmi_dir =
                       let info = Lib.info lib in
                       obj_dir_of_lib `Public mode (Lib_info.obj_dir info)
                     in
                     Path.Set.add obj_dirs public_cmi_dir )))
      in
      let src_dirs =
        Path.Set.union src_dirs
          (Path.Set.of_list_map ~f:Path.source more_src_dirs)
      in
      let+ melc_flags =
        match t.config.mode with
        | Ocaml _ -> Action_builder.return []
        | Melange -> (
          let+ melc_compiler =
            Action_builder.of_memo (Melange_binary.melc sctx ~loc:None ~dir)
          in
          match melc_compiler with
          | Error _ -> []
          | Ok path ->
            [ Processed.Pp_kind.to_flag Ppx
            ; Processed.serialize_path path ^ " -as-ppx"
            ])
      in
      { Processed.stdlib_dir
      ; src_dirs
      ; obj_dirs
      ; flags
      ; extensions
      ; melc_flags
      }
    and+ pp_config = pp_config t sctx ~expander in
    let per_module_config =
      (* And copy for each module the resulting pp flags *)
      Modules.fold_no_vlib modules ~init:[] ~f:(fun m init ->
          Module.sources m
          |> Path.Build.Set.of_list_map ~f:(fun src ->
                 Path.as_in_build_dir_exn src |> remove_extension)
          |> Path.Build.Set.fold ~init ~f:(fun src acc ->
                 let config =
                   { Processed.module_ = Module.set_pp m None
                   ; opens =
                       Modules.alias_for modules m |> List.map ~f:Module.name
                   }
                 in
                 (src, config) :: acc))
      |> Path.Build.Map.of_list_exn
    in
    { Processed.pp_config; config; per_module_config }
end

let dot_merlin sctx ~dir ~more_src_dirs ~expander (t : Unprocessed.t) =
  let open Memo.O in
  let merlin_file = Merlin_ident.merlin_file_path dir t.ident in
  let* () =
    Rules.Produce.Alias.add_deps (Alias.check ~dir)
      (Action_builder.path (Path.build merlin_file))
  in
  let action =
    Unprocessed.process t sctx ~dir ~more_src_dirs ~expander
    |> Action_builder.map ~f:Processed.Persist.to_string
    |> Action_builder.with_no_targets
    |> Action_builder.With_targets.write_file_dyn merlin_file
  in
  Super_context.add_rule sctx ~dir action

let add_rules sctx ~dir ~more_src_dirs ~expander merlin =
  Memo.when_ (Super_context.context sctx).merlin (fun () ->
      dot_merlin sctx ~more_src_dirs ~expander ~dir merlin)

include Unprocessed
