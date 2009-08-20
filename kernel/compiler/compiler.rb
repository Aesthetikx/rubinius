##
# Turns text into CompiledMethods

class Compiler

  Config = Hash.new

  ##
  # Compiler error subclass.

  class Error < RuntimeError
  end

  class Context
    def initialize(variables, method)
      @variables = variables
      @method = method
    end

    attr_accessor :variables
    attr_accessor :method

    def dynamic_locals
      @variables.dynamic_locals
    end

    def set_eval_local(name, val)
      dynamic_locals[name] = val
    end
  end
  
  class LiterateRB

    def self.to_code(file, options); new(file).to_code(options); end

    attr_accessor :file
    attr_accessor :code
    attr_accessor :comments

    def initialize(file)
      @file     = file
      @code     = []
      @comments = []
      @in_code  = false

      parse
    end

    def to_code(options)
      coms = @comments.map {|c| !c || c.empty? ? nil : "# #{c}" }
      coms = [nil] * @code.size unless options[:comments]
      tree = @code.zip(coms).map {|(a, b)| a || b }.compact
      tree.join "\n"
    end

    private

    def parse
      File.open @file do |file|  # used in keeping memory footprint down
        file.each_line do |line| # keep it constant space
          case line
          when /\s*>(.*)/
            @code << $1
            @comments << nil
          when /\s*\\begin\{code\}\s*/
            @in_code = true
          when /\s*\\end\{code\}\s*/
            @in_code = false
          else
            if @in_code
              @code << line.chomp
              @comments << nil
            else
              @comments << line.chomp
              @code << nil
            end
          end
        end
      end
    end
  end

  def self.process_flags(flags)
    flags.each { |f| Config[f] = true } if flags
  end

  def self.parse_flags(stream)
    to_clear = []
    stream.each do |token|
      if token.prefix? "-f"
        to_clear << token
        name, val = token[2..-1].split("=")
        val = true unless val
        Config[name] = val
      end
    end

    to_clear.each { |t| stream.delete(t) }
  end

  ## 
  # +path+ is either a normal ruby file or a literate ruby file.
  def self.compile_file(path, flags=nil, options={})
    process_flags(flags)

    if path =~ /\.lrb$/ or options[:lrb]
      # we produce a string that is the code, and then convert it to sexps
      sexp = LiterateRB::to_code(path, :comments => false).to_sexp
    else
      sexp = File.to_sexp(path)
    end

    comp = new(Generator)
    node = comp.into_script(sexp)
    return node.to_description(:__script__).to_cmethod
  end

  def self.compile_string(string, binding, file = "(eval)", line = 1)
    sexp = string.to_sexp(file, line)

    node    = new(Generator, binding).convert_sexp(s(:eval_expression, sexp))
    desc    = node.to_description(:__eval_script__)
    desc.for_block = true
    cm      = desc.to_cmethod
    cm.file = file.to_sym

    return cm
  end

  TimeEpoch = 1141027200 # rubinius' birthday

  @version_number = nil

  def self.version_number
    unless @version_number
      begin
        # handled for .rba files in init.rb
        dir = $LOAD_PATH.detect { |path| File.file? "#{path}/compiler/compiler.rb" }
        max = Dir["#{dir}/compiler/*.rb"].map { |f| File.mtime(f).to_i }.max
        @version_number = max - TimeEpoch
      rescue Exception
        @version_number = 0
      end

      if $DEBUG_LOADING
        STDERR.puts "[Compiler version: #{@version_number}]"
      end
    end
    return @version_number
  end

  def self.version_number=(ver)
    if ver
      @version_number = ver - TimeEpoch
    else
      @version_number = 0
    end

    if $DEBUG_LOADING
      STDERR.puts "[Compiler version: #{@version_number} (forced)]"
    end
  end

  def initialize(gen_class, context=nil)
    @variables = {}
    @generator_class = gen_class
    @plugins = Hash.new { |h,k| h[k]= [] }

    @file = "(unknown)"
    @line = 0
    @context = context

    @kernel = Config['rbx-kernel']
    load_plugins
  end

  def kernel?
    @kernel
  end

  def custom_scopes?
    @context
  end

  def create_scopes
    ctx = @context
    all_scopes = []
    block_scopes = []
    dynamic = []

    vars = ctx.variables
    while vars.parent
      scope = LocalScope.new(nil)
      scope.from_eval = true
      block_scopes.unshift scope
      all_scopes << scope

      # TODO should check for from_eval here?
      if names = vars.method.local_names
        i = 0
        names.each do |name|
          scope[name].created_in_block! i
          i += 1
        end
      end

      vars = vars.parent
    end

    top_scope = LocalScope.new(nil)
    top_scope.from_eval = true
    all_scopes << top_scope

    i = 0
    if names = vars.method.local_names
      names.each do |name|
        top_scope[name].slot = i
        i += 1
      end
    end

    return [top_scope, block_scopes, all_scopes, @context]
  end

  attr_reader :plugins
  attr_accessor :generator_class

  def set_position(file, line)
    @file, @line = file, line
  end

  def current_file
    @file
  end

  def current_line
    @line
  end

  def load_plugins
    # The default plugins
    activate_default :block_given
    activate_default :primitive
    activate_default :assembly
    activate_default :fastmath
    activate_default :current_method
    activate :const_expr if Config['rbx-kernel']
    activate :kernel_methods if Config['rbx-kernel']
    activate_default :fastsystem
    activate_default :fastgeneric
    # activate_default :fastnew
    # AutoPrimitiveDetection is currently disabled
    # TODO - Implement the opt_* primitives it requires and reactivate
    # activate_default :auto_primitive
    activate_default :privately
    activate :fast_coerce if Config['rbx-kernel']
  end

  def activate_default(name)
    activate(name) unless Config["no-#{name}"]
  end

  def activate(name)
    cls = Plugins.find_plugin(name)
    raise Error, "Unknown plugin '#{name}'" unless cls
    @plugins[cls.kind] << cls.new(self)
  end

  def inspect
    "#<#{self.class}>"
  end

  def convert_sexp(sexp)
    return nil if sexp.nil?
    raise ArgumentError, "input must be a Sexp: #{sexp.inspect}" unless
      Sexp === sexp

    klass = Node::Mapping[sexp.first]

    raise Error, "Unable to resolve '#{sexp.first.inspect}'" unless klass

    return klass.create(self, sexp)
  end

  def into_script(sexp)
    begin
      convert_sexp(s(:script, sexp))
    rescue Object => e
      puts "Compilation error detected: #{e.message}"
      puts "   near #{@file}:#{@line}"
      puts
      puts e.awesome_backtrace.show
    end
  end

  def get(tag)
    @variables[tag]
  end

  def set(tag, val=true)
    if tag.kind_of? Hash
      cur = @variables.dup
      @variables.merge! tag
      begin
        yield
      ensure
        @variables = cur
      end
    else
      cur = @variables[tag]
      @variables[tag] = val
      begin
        yield
      ensure
        @variables[tag] = cur
      end
    end
  end

  ##
  # Raised when turning the AST into bytecode fails in some way.

  class GenerationError < Error; end

  def show_errors(gen) # TODO: remove
    begin
      yield
    rescue GenerationError => e
      raise e
    rescue Object => e
      puts "Bytecode generation error: "
      puts "   #{e.message} (#{e.class})"
      puts "   near #{gen.file||'<missing file>'}:#{gen.line||'<missing line>'}"
      puts ""
      puts e.backtrace

      raise GenerationError, "unable to generate bytecode"
    end
  end

end
