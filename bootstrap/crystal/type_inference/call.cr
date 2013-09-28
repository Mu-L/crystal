require "../ast"
require "../types"

module Crystal
  class Call
    setter :mod
    property :scope
    property :parent_visitor
    property :target_defs
    property :target_macro

    def mod
      if @mod
        @mod
      else
        raise "BUG: @mod is nil"
      end
    end

    def target_def
      # TODO: fix
      if (defs = @target_defs)
        if defs.length == 1
          return defs[0]
        end
      end

      raise "Zero or more than one target def for #{self}"
    end

    def update_input
      recalculate
    end

    def recalculate
      obj = @obj

      if obj && (obj_type = obj.type) && obj_type.is_a?(LibType)
        recalculate_lib_call(obj_type)
        return
      end

      # elsif !obj || (obj.type && !obj.type.is_a?(LibType))
      #   check_not_lib_out_args
      # end

      # return unless obj_and_args_types_set?

      # Ignore extra recalculations when more than one argument changes at the same time
      # types_signature = args.map { |arg| arg.type.type_id }
      # types_signature << obj.type.type_id if obj
      # return if @types_signature == types_signature
      # @types_signature = types_signature

      # unbind_from *@target_defs if @target_defs
      # unbind_from block.break if block
      # @subclass_notifier.remove_subclass_observer(self) if @subclass_notifier

      @target_defs = nil

      # if obj
      #   if obj.type.is_a?(UnionType)
      #     matches = []
      #     obj.type.each do |type|
      #       matches.concat lookup_matches_in(type)
      #     end
      #   else
      #     matches = lookup_matches_in(obj.type)
      #   end
      # else
      #   if name == 'super'
      #     matches = lookup_matches_in_super
      #   else
          # matches = lookup_matches_in(scope) || lookup_matches_in(mod)
      #   end
      # end

      if obj
        matches = lookup_matches_in(obj.type)
      else
        matches = lookup_matches_in(mod)
      end

      # puts matches

      # If @target_defs is set here it means there was a recalculation
      # fired as a result of a recalculation. We keep the last one.

      return if @target_defs

      @target_defs = matches

      bind_to matches if matches

      # bind_to *matches
      # bind_to block.break if block

      # if parent_visitor && parent_visitor.typed_def && matches.any?(&:raises)
      #   parent_visitor.typed_def.raises = true
      # end
    end

    def lookup_matches_in(owner : Type, self_type = owner, def_name = self.name)
      arg_types = args.map &.type
      matches = owner.lookup_matches(def_name, arg_types, !!block)

      if matches.empty?
        raise_matches_not_found(matches.owner || owner, def_name, matches)
      end

      typed_defs = matches.map do |match|
        block_type = nil
        use_cache = true
        match_owner = match.owner
        typed_def = match_owner.lookup_def_instance(match.def.object_id, match.arg_types, block_type) if use_cache
        unless typed_def
          prepared_typed_def = prepare_typed_def_with_args(match.def, owner, match_owner, match.arg_types)
          typed_def = prepared_typed_def.typed_def
          typed_def_args = prepared_typed_def.args
          match_owner.add_def_instance(match.def.object_id, match.arg_types, block_type, typed_def) if use_cache
          if typed_def.body
  #         bubbling_exception do
            visitor = TypeVisitor.new(mod, typed_def_args, match_owner, parent_visitor, self, owner, match.def, typed_def, match.arg_types, match.free_vars) # , yield_vars)
            typed_def.body.accept visitor
  #         end
          end
        end
        typed_def
      end
    end

    def lookup_matches_in(owner : Nil)
      raise "Bug: trying to lookup matches in nil in #{self}"
    end

    def recalculate_lib_call(obj_type)
      old_target_defs = @target_defs

      untyped_def = obj_type.lookup_first_def(name, false) #or
      raise "undefined fun '#{name}' for #{obj_type}" unless untyped_def

      # check_args_length_match untyped_def
      # check_lib_out_args untyped_def
      # return unless obj_and_args_types_set?

      # check_fun_args_types_match untyped_def

      untyped_defs = [untyped_def]
      @target_defs = untyped_defs

      # self.unbind_from *old_target_defs if old_target_defs
      self.bind_to untyped_defs
    end

    def raise_matches_not_found(owner, def_name, matches = nil)
      defs = owner.lookup_defs(def_name)
      if defs.empty?
        if obj || !owner.is_a?(Program)
          error_msg = "undefined method '#{name}' for #{owner}"
          # similar_name = owner.lookup_similar_defs(def_name, self.args.length, !!block)
          # error_msg << " \033[1;33m(did you mean '#{similar_name}'?)\033[0m" if similar_name
          raise error_msg#, owner_trace
        elsif args.length > 0 || has_parenthesis
          raise "undefined method '#{name}'"#, owner_trace
        else
          raise "undefined local variable or method '#{name}'"#, owner_trace
        end
      end

      defs_matching_args_length = defs.select { |a_def| a_def.args.length == self.args.length }
      if defs_matching_args_length.empty?
        all_arguments_lengths = defs.map { |a_def| a_def.args.length }.uniq!
        raise "wrong number of arguments for '#{full_name(owner)}' (#{args.length} for #{all_arguments_lengths.join ", "})"
      end

      msg = "no overload matches '#{full_name(owner)}'"
      raise msg
    end

    def full_name(owner)
      owner.is_a?(Program) ? name : "#{owner}##{name}"
    end

    class PreparedTypedDef
      getter :typed_def
      getter :args

      def initialize(@typed_def, @args)
      end
    end

    def prepare_typed_def_with_args(untyped_def, owner, self_type, arg_types)
      args_start_index = 0

      typed_def = untyped_def.clone
      typed_def.owner = self_type

      if body = typed_def.body
        typed_def.bind_to body
      end

      args = {} of String => Var

      if self_type.is_a?(Type)
        args["self"] = Var.new("self", self_type)
      end

      0.upto(self.args.length - 1) do |index|
        arg = typed_def.args[index]
        type = arg_types[args_start_index + index]
        var = Var.new(arg.name, type)
        var.location = arg.location
        var.bind_to(var)
        args[arg.name] = var
        arg.type = type
      end

      PreparedTypedDef.new(typed_def, args)
    end

  end
end
