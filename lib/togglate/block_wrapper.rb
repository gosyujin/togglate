require "timeout"

class Togglate::BlockWrapper
  def initialize(text,
                 wrapper:%w(<!--original -->),
                 pretext:"[translation here]",
                 wrap_exceptions:[],
                 **opts)
    @text = text
    @wrapper = wrapper
    @pretext = pretext
    @wrap_exceptions = wrap_exceptions
    @translate = set_translate_opt(opts[:translate])
    @timeout = opts.fetch(:timeout, 5)
    @email = opts[:email]
    @indent_re = /^\s{4,}\S/
    self_closing_tags = %w(img br hr !--).join('|')
    @html_tag_re = /^<(?!#{self_closing_tags}).+>\s*$/
  end

  def run
    wrap_chunks build_chunks
  end

  private
  def build_chunks
    in_block = false
    in_indent = false
    @text.each_line.chunk do |line|
      in_block = in_block?(line, in_block)
      prev_indent = in_indent
      in_indent = in_indented_block?(line, in_indent, in_block)

      if true_to_false?(prev_indent, in_indent)
        if blank_line?(line)
         true
        else
        :_alone  # line just after 4 indent block marked :_alone
        end
      else
        blank_line?(line) && !in_block && !in_indent
      end
    end
  end

  def blank_line?(line, blank_line_re:/^\s*$/)
    !line.match(blank_line_re).nil?
  end

  def true_to_false?(prev, curr)
    # this captures the in-out state transition on 4 indent block.
    [prev, curr] == [true, false]
  end

  def in_block?(line, in_block, block_tags:[/^```/, /^{%/, @html_tag_re])
    return !in_block if block_tags.any? { |ex| line.match ex }
    in_block
  end

  def in_indented_block?(line, status, in_block)
    return false if in_block
    if !status && line.match(@indent_re) ||
        status && line.match(/^\s{,3}\S/)
      !status
    else
      status
    end
  end

  def wrap_chunks(chunks)
    # a line just after 4 indent block(marked :_alone) is
    # saved to local var 'reserve', then it is merged with
    # next lines or wrapped solely depend the type of next lines
    reserve = nil
    wrap_lines = chunks.inject([]) do |m, (is_blank_line, lines)|
      next m.tap { reserve = lines } if is_blank_line == :_alone

      if is_blank_line || exception_block?(lines.first)
        if reserve
          m.push "\n"
          m.push *wrapped_block(reserve)
        end
        m.push *lines
      else
        if reserve
          m.push "\n"
          lines = reserve + lines
        end
        m.push *wrapped_block(lines)
      end
      m.tap { reserve = nil }
    end
    @translate ? hash_to_translation(wrap_lines).join : wrap_lines.join
  end

  def wrapped_block(contents)
    [
      pretext(contents),
      "\n\n",
      @wrapper[0],
      "\n",
      *contents,
      @wrapper[1],
      "\n"
    ]
  end

  def exception_block?(line)
    if @wrap_exceptions.empty?
      false
    else
      (@wrap_exceptions + [@indent_re]).any? { |ex| line.match ex }
    end
  end

  def pretext(lines)
    if @translate
      hash_value = lines.join.hash
      sentences_to_translate[hash_value] = lines.join
      hash_value
    else
      @pretext
    end
  end

  def set_translate_opt(opt)
    case opt
    when Hash, FalseClass, NilClass
      opt
    when TrueClass
      {to: :ja}
    else
      raise ArgumentError
    end
  end

  def sentences_to_translate
    @sentences_to_translate ||= {}
  end

  def hash_to_translation(lines)
    translates = request_translation
    lines.map { |line| translates[line] || line }
  end

  def request_translation
    Mymemory.config.email = @email if @email
    res = {}
    thread_with(sentences_to_translate) do |k, text|
      begin
        timeout(@timeout) { res[k] = ::Mymemory.translate(text, @translate) }
      rescue Timeout::Error
        res[k] = @pretext
      end
    end
    res
  end

  def thread_with(hash)
    mem = []
    hash.map do |*item|
      Thread.new(*item) do |*_item|
        mem << yield(*_item)
      end
    end.each(&:join)
    mem
  end
end
