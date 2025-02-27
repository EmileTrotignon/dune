(** This module ensures that one merlin configuration file is generated for each
    stanza. Each of these configuration files is accompanied by a merlin exist
    file. Each of these files contain a map from every module involved in the
    stanza to a standard merlin configuration. The [Processed.t] type represents
    the Merlin configuration as it will be marshalled to and from the
    configuration files, while [Merlin.t] represents raw information coming from
    the build system. *)

open Import

(** Type of "unprocessed" merlin information *)
type t

module Processed : sig
  (** Type of "processed" merlin information *)
  type t

  val load_file : Path.t -> (t, string) result

  (** [print_file path] reads the configuration at path [path] and print it as a
      s-expression *)
  val print_file : Path.t -> unit

  (** [print_generic_dot_merlin paths] will merge the given configurations and
      print the resulting configuration in dot-merlin syntax. *)
  val print_generic_dot_merlin : Path.t list -> unit

  val get : t -> filename:string -> Sexp.t option
end

val make :
     ?requires:Lib.t list Resolve.t
  -> stdlib_dir:Path.t
  -> flags:Ocaml_flags.t
  -> ?preprocess:
       Preprocess.Without_instrumentation.t Preprocess.t Module_name.Per_item.t
  -> ?libname:Lib_name.Local.t
  -> ?source_dirs:Path.Source.Set.t
  -> modules:Modules.t
  -> obj_dir:Path.Build.t Obj_dir.t
  -> dialects:Dialect.DB.t
  -> ident:Merlin_ident.t
  -> modes:[ `Lib of Lib_mode.Map.Set.t | `Exe ]
  -> unit
  -> t

(** Add rules for generating the merlin configuration of a specific stanza
    identified by [ident] in a directory *)
val add_rules :
     Super_context.t
  -> dir:Path.Build.t
  -> more_src_dirs:Path.Source.t list
  -> expander:Expander.t
  -> t
  -> unit Memo.t
