defmodule ElixirLS.LanguageServer.SourceFileTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ElixirLS.LanguageServer.SourceFile
  import ElixirLS.LanguageServer.RangeUtils

  test "format_spec/2 with nil" do
    assert SourceFile.format_spec(nil, []) == ""
  end

  test "format_spec/2 with empty string" do
    assert SourceFile.format_spec("", []) == ""
  end

  test "format_spec/2 with a plain string" do
    spec = "@spec format_spec(String.t(), keyword()) :: String.t()"

    assert SourceFile.format_spec(spec, line_length: 80) == """

           ```elixir
           @spec format_spec(String.t(), keyword()) :: String.t()
           ```
           """
  end

  test "format_spec/2 with a spec that needs to be broken over lines" do
    spec = "@spec format_spec(String.t(), keyword()) :: String.t()"

    assert SourceFile.format_spec(spec, line_length: 30) == """

           ```elixir
           @spec format_spec(
                   String.t(),
                   keyword()
                 ) :: String.t()
           ```
           """
  end

  def new(text) do
    %SourceFile{text: text, version: 0}
  end

  describe "apply_content_changes" do
    # tests and helper functions ported from https://github.com/microsoft/vscode-languageserver-node
    # note thet those functions are not production quality e.g. they don't deal with utf8/utf16 encoding issues
    defp index_of(string, substring) do
      case String.split(string, substring, parts: 2) do
        [left, _] -> String.to_charlist(left) |> length
        [_] -> -1
      end
    end

    def get_line_offsets(""), do: %{0 => 0}

    def get_line_offsets(text) do
      chars =
        text
        |> String.to_charlist()

      shifted =
        chars
        |> tl
        |> Kernel.++([nil])

      Enum.zip(chars, shifted)
      |> Enum.with_index()
      |> Enum.reduce({[0], nil}, fn
        _, {acc, :skip} ->
          {acc, nil}

        {{g, gs}, i}, {acc, nil} when g in [?\r, ?\n] ->
          if g == ?\r and gs == ?\n do
            {[i + 2 | acc], :skip}
          else
            {[i + 1 | acc], nil}
          end

        _, {acc, nil} ->
          {acc, nil}
      end)
      |> elem(0)
      |> Enum.reverse()
      |> Enum.with_index()
      |> Map.new(fn {off, ind} -> {ind, off} end)
    end

    defp find_low_high(low, high, offset, line_offsets) when low < high do
      mid = floor((low + high) / 2)

      if line_offsets[mid] > offset do
        find_low_high(low, mid, offset, line_offsets)
      else
        find_low_high(mid + 1, high, offset, line_offsets)
      end
    end

    defp find_low_high(low, _high, _offset, _line_offsets), do: low

    def position_at(text, offset) do
      offset = max(min(offset, String.to_charlist(text) |> length), 0)

      line_offsets = get_line_offsets(text)
      low = 0
      high = map_size(line_offsets)

      if high == 0 do
        %GenLSP.Structures.Position{line: 0, character: offset}
      else
        low = find_low_high(low, high, offset, line_offsets)

        # low is the least x for which the line offset is larger than the current offset
        # or array.length if no line offset is larger than the current offset
        line = low - 1
        %GenLSP.Structures.Position{line: line, character: offset - line_offsets[line]}
      end
    end

    def position_create(l, c) do
      %GenLSP.Structures.Position{line: l, character: c}
    end

    def position_after_substring(text, sub_text) do
      index = index_of(text, sub_text)
      position_at(text, index + (String.to_charlist(sub_text) |> length))
    end

    def range_for_substring(source_file, sub_text) do
      index = index_of(source_file.text, sub_text)

      %GenLSP.Structures.Range{
        start: position_at(source_file.text, index),
        end: position_at(source_file.text, index + (String.to_charlist(sub_text) |> length))
      }
    end

    def range_after_substring(source_file, sub_text) do
      pos = position_after_substring(source_file.text, sub_text)
      %GenLSP.Structures.Range{start: pos, end: pos}
    end

    test "empty update" do
      assert %SourceFile{text: "abc123"} =
               SourceFile.apply_content_changes(new("abc123"), [])
    end

    test "full update" do
      assert %SourceFile{text: "efg456"} =
               SourceFile.apply_content_changes(new("abc123"), [%{text: "efg456"}])

      assert %SourceFile{text: "world"} =
               SourceFile.apply_content_changes(new("abc123"), [
                 %{text: "hello"},
                 %{text: "world"}
               ])
    end

    test "incrementally removing content" do
      sf = new("function abc() {\n  console.log(\"hello, world!\");\n}")

      assert %SourceFile{text: "function abc() {\n  console.log(\"\");\n}"} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   text: "",
                   range: range_for_substring(sf, "hello, world!")
                 }
               ])
    end

    test "incrementally removing multi-line content" do
      sf = new("function abc() {\n  foo();\n  bar();\n  \n}")

      assert %SourceFile{text: "function abc() {\n  \n}"} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   text: "",
                   range: range_for_substring(sf, "  foo();\n  bar();\n")
                 }
               ])
    end

    test "incrementally removing multi-line content 2" do
      sf = new("function abc() {\n  foo();\n  bar();\n  \n}")

      assert %SourceFile{text: "function abc() {\n  \n  \n}"} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   text: "",
                   range: range_for_substring(sf, "foo();\n  bar();")
                 }
               ])
    end

    test "incrementally adding content" do
      sf = new("function abc() {\n  console.log(\"hello\");\n}")

      assert %SourceFile{
               text: "function abc() {\n  console.log(\"hello, world!\");\n}"
             } =
               SourceFile.apply_content_changes(sf, [
                 %{
                   text: ", world!",
                   range: range_after_substring(sf, "hello")
                 }
               ])
    end

    test "incrementally adding multi-line content" do
      sf = new("function abc() {\n  while (true) {\n    foo();\n  };\n}")

      assert %SourceFile{
               text: "function abc() {\n  while (true) {\n    foo();\n    bar();\n  };\n}"
             } =
               SourceFile.apply_content_changes(sf, [
                 %{
                   text: "\n    bar();",
                   range: range_after_substring(sf, "foo();")
                 }
               ])
    end

    test "incrementally replacing single-line content, more chars" do
      sf = new("function abc() {\n  console.log(\"hello, world!\");\n}")

      assert %SourceFile{
               text: "function abc() {\n  console.log(\"hello, test case!!!\");\n}"
             } =
               SourceFile.apply_content_changes(sf, [
                 %{
                   text: "hello, test case!!!",
                   range: range_for_substring(sf, "hello, world!")
                 }
               ])
    end

    test "incrementally replacing single-line content, less chars" do
      sf = new("function abc() {\n  console.log(\"hello, world!\");\n}")

      assert %SourceFile{text: "function abc() {\n  console.log(\"hey\");\n}"} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   text: "hey",
                   range: range_for_substring(sf, "hello, world!")
                 }
               ])
    end

    test "incrementally replacing single-line content, same num of chars" do
      sf = new("function abc() {\n  console.log(\"hello, world!\");\n}")

      assert %SourceFile{
               text: "function abc() {\n  console.log(\"world, hello!\");\n}"
             } =
               SourceFile.apply_content_changes(sf, [
                 %{
                   text: "world, hello!",
                   range: range_for_substring(sf, "hello, world!")
                 }
               ])
    end

    test "incrementally replacing multi-line content, more lines" do
      sf = new("function abc() {\n  console.log(\"hello, world!\");\n}")

      assert %SourceFile{
               text: "\n//hello\nfunction d(){\n  console.log(\"hello, world!\");\n}"
             } =
               SourceFile.apply_content_changes(sf, [
                 %{
                   text: "\n//hello\nfunction d(){",
                   range: range_for_substring(sf, "function abc() {")
                 }
               ])
    end

    test "incrementally replacing multi-line content, less lines" do
      sf = new("a1\nb1\na2\nb2\na3\nb3\na4\nb4\n")

      assert %SourceFile{text: "a1\nb1\na2\nb2xx\nyy"} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   text: "xx\nyy",
                   range: range_for_substring(sf, "\na3\nb3\na4\nb4\n")
                 }
               ])
    end

    test "incrementally replacing multi-line content, same num of lines and chars" do
      sf = new("a1\nb1\na2\nb2\na3\nb3\na4\nb4\n")

      assert %SourceFile{text: "a1\nb1\n\nxx1\nxx2\nb3\na4\nb4\n"} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   text: "\nxx1\nxx2",
                   range: range_for_substring(sf, "a2\nb2\na3")
                 }
               ])
    end

    test "incrementally replacing multi-line content, same num of lines but diff chars" do
      sf = new("a1\nb1\na2\nb2\na3\nb3\na4\nb4\n")

      assert %SourceFile{text: "a1\nb1\n\ny\n\nb3\na4\nb4\n"} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   text: "\ny\n",
                   range: range_for_substring(sf, "a2\nb2\na3")
                 }
               ])
    end

    test "incrementally replacing multi-line content, huge number of lines" do
      sf = new("a1\ncc\nb1")
      text = for _ <- 1..20000, into: "", do: "\ndd"

      assert %SourceFile{text: res} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   text: text,
                   range: range_for_substring(sf, "\ncc")
                 }
               ])

      assert res == "a1" <> text <> "\nb1"
    end

    test "several incremental content changes" do
      sf = new("function abc() {\n  console.log(\"hello, world!\");\n}")

      assert %SourceFile{
               text: "function abcdefghij() {\n  console.log(\"hello, test case!!!\");\n}"
             } =
               SourceFile.apply_content_changes(sf, [
                 %{
                   text: "defg",
                   range: range(0, 12, 0, 12)
                 },
                 %{
                   text: "hello, test case!!!",
                   range: range(1, 15, 1, 28)
                 },
                 %{
                   text: "hij",
                   range: range(0, 16, 0, 16)
                 }
               ])
    end

    test "basic append" do
      sf = new("foooo\nbar\nbaz")

      assert %SourceFile{text: "foooo\nbar some extra content\nbaz"} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   text: " some extra content",
                   range: range(1, 3, 1, 3)
                 }
               ])
    end

    test "multi-line append" do
      sf = new("foooo\nbar\nbaz")

      assert %SourceFile{text: "foooo\nbar some extra\ncontent\nbaz"} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   text: " some extra\ncontent",
                   range: range(1, 3, 1, 3)
                 }
               ])
    end

    test "basic delete" do
      sf = new("foooo\nbar\nbaz")

      assert %SourceFile{text: "foooo\n\nbaz"} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   text: "",
                   range: range(1, 0, 1, 3)
                 }
               ])
    end

    test "multi-line delete" do
      sf = new("foooo\nbar\nbaz")

      assert %SourceFile{text: "foooo\nbaz"} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   text: "",
                   range: range(0, 5, 1, 3)
                 }
               ])
    end

    test "single character replace" do
      sf = new("foooo\nbar\nbaz")

      assert %SourceFile{text: "foooo\nbaz\nbaz"} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   text: "z",
                   range: range(1, 2, 1, 3)
                 }
               ])
    end

    test "multi-character replace" do
      sf = new("foo\nbar")

      assert %SourceFile{text: "foo\nfoobar"} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   text: "foobar",
                   range: range(1, 0, 1, 3)
                 }
               ])
    end

    test "windows line endings are preserved in document" do
      sf = new("foooo\r\nbar\rbaz")

      assert %SourceFile{text: "foooo\r\nbaz\rbaz"} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   text: "z",
                   range: range(1, 2, 1, 3)
                 }
               ])
    end

    test "windows line endings are preserved in inserted text" do
      sf = new("foooo\nbar\nbaz")

      assert %SourceFile{text: "foooo\nbaz\r\nz\rz\nbaz"} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   text: "z\r\nz\rz",
                   range: range(1, 2, 1, 3)
                 }
               ])
    end

    test "utf8 codons are preserved in document" do
      sf = new("foooo\nb🏳️‍🌈r\nbaz")

      assert %SourceFile{text: "foooo\nb🏳️‍🌈z\nbaz"} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   text: "z",
                   range: range(1, 7, 1, 8)
                 }
               ])
    end

    test "utf8 codonss are preserved in inserted text" do
      sf = new("foooo\nbar\nbaz")

      assert %SourceFile{text: "foooo\nbaz🏳️‍🌈z\nbaz"} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   text: "z🏳️‍🌈z",
                   range: range(1, 2, 1, 3)
                 }
               ])
    end

    test "invalid update range - before the document starts -> before the document starts" do
      sf = new("foo\nbar")

      assert %SourceFile{text: "abc123foo\nbar"} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   text: "abc123",
                   range: range(-2, 0, -1, 3)
                 }
               ])
    end

    test "invalid update range - before the document starts -> the middle of document" do
      sf = new("foo\nbar")

      assert %SourceFile{text: "foobar\nbar"} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   text: "foobar",
                   range: range(-1, 0, 0, 3)
                 }
               ])
    end

    test "invalid update range - the middle of document -> after the document ends" do
      sf = new("foo\nbar")

      assert %SourceFile{text: "foo\nfoobar"} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   text: "foobar",
                   range: range(1, 0, 1, 10)
                 }
               ])
    end

    test "invalid update range - after the document ends -> after the document ends" do
      sf = new("foo\nbar")

      assert %SourceFile{text: "foo\nbarabc123"} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   text: "abc123",
                   range: range(3, 0, 6, 10)
                 }
               ])
    end

    test "invalid update range - before the document starts -> after the document ends" do
      sf = new("foo\nbar")

      assert %SourceFile{text: "entirely new content"} =
               SourceFile.apply_content_changes(sf, [
                 %{
                   text: "entirely new content",
                   range: range(-1, 1, 2, 10000)
                 }
               ])
    end
  end

  test "lines" do
    assert [""] == SourceFile.lines("")
    assert ["abc"] == SourceFile.lines("abc")
    assert ["", ""] == SourceFile.lines("\n")
    assert ["a", ""] == SourceFile.lines("a\n")
    assert ["", "a"] == SourceFile.lines("\na")
    assert ["ABCDE", "FGHIJ"] == SourceFile.lines("ABCDE\rFGHIJ")
    assert ["ABCDE", "FGHIJ"] == SourceFile.lines("ABCDE\r\nFGHIJ")
    assert ["ABCDE", "", "FGHIJ"] == SourceFile.lines("ABCDE\n\nFGHIJ")
    assert ["ABCDE", "", "FGHIJ"] == SourceFile.lines("ABCDE\r\rFGHIJ")
    assert ["ABCDE", "", "FGHIJ"] == SourceFile.lines("ABCDE\n\rFGHIJ")
  end

  test "full_range" do
    assert %GenLSP.Structures.Range{
             end: %GenLSP.Structures.Position{character: 0, line: 0},
             start: %GenLSP.Structures.Position{character: 0, line: 0}
           } = SourceFile.full_range(new(""))

    assert %GenLSP.Structures.Range{
             end: %GenLSP.Structures.Position{character: 1, line: 0}
           } = SourceFile.full_range(new("a"))

    assert %GenLSP.Structures.Range{
             end: %GenLSP.Structures.Position{character: 0, line: 1}
           } = SourceFile.full_range(new("\n"))

    assert %GenLSP.Structures.Range{
             end: %GenLSP.Structures.Position{character: 2, line: 1}
           } = SourceFile.full_range(new("a\naa"))

    assert %GenLSP.Structures.Range{
             end: %GenLSP.Structures.Position{character: 2, line: 1}
           } = SourceFile.full_range(new("a\r\naa"))

    assert %GenLSP.Structures.Range{
             end: %GenLSP.Structures.Position{character: 8, line: 1}
           } = SourceFile.full_range(new("a\naa🏳️‍🌈"))
  end

  describe "lines_with_endings/1" do
    test "with an empty string" do
      assert SourceFile.lines_with_endings("") == [{"", nil}]
    end

    test "beginning with endline" do
      assert SourceFile.lines_with_endings("\n") == [{"", "\n"}, {"", nil}]
      assert SourceFile.lines_with_endings("\nbasic") == [{"", "\n"}, {"basic", nil}]
    end

    test "without any endings" do
      assert SourceFile.lines_with_endings("basic") == [{"basic", nil}]
    end

    test "with a LF" do
      assert SourceFile.lines_with_endings("text\n") == [{"text", "\n"}, {"", nil}]
    end

    test "with a CR LF" do
      assert SourceFile.lines_with_endings("text\r\n") == [{"text", "\r\n"}, {"", nil}]
    end

    test "with a CR" do
      assert SourceFile.lines_with_endings("text\r") == [{"text", "\r"}, {"", nil}]
    end

    test "with multiple LF lines" do
      assert SourceFile.lines_with_endings("line1\nline2\nline3") == [
               {"line1", "\n"},
               {"line2", "\n"},
               {"line3", nil}
             ]
    end

    test "with multiple CR LF line endings" do
      text = "A\r\nB\r\n\r\nC"

      assert SourceFile.lines_with_endings(text) == [
               {"A", "\r\n"},
               {"B", "\r\n"},
               {"", "\r\n"},
               {"C", nil}
             ]
    end

    test "with an emoji" do
      text = "👨‍👩‍👦 test"
      assert SourceFile.lines_with_endings(text) == [{"👨‍👩‍👦 test", nil}]
    end

    test "example multi-byte string" do
      text = "𐂀"
      assert String.valid?(text)
      [{line, ending}] = SourceFile.lines_with_endings(text)
      assert String.valid?(line)
      assert ending in ["\r\n", "\n", "\r", nil]
    end

    property "always creates valid binaries" do
      check all(
              elements <-
                list_of(
                  one_of([
                    string(:printable),
                    one_of([constant("\r\n"), constant("\n"), constant("\r")])
                  ])
                )
            ) do
        text = List.to_string(elements)
        lines_w_endings = SourceFile.lines_with_endings(text)

        Enum.each(lines_w_endings, fn {line, ending} ->
          assert String.valid?(line)
          assert ending in ["\r\n", "\n", "\r", nil]
        end)
      end
    end
  end

  describe "characters_to_binary!/3" do
    test "raises for invalid utf8" do
      assert_raise ArgumentError, ~r/could not convert characters/, fn ->
        SourceFile.line_length_utf16(<<0x80>>)
      end
    end
  end

  describe "positions" do
    test "lsp_position_to_elixir empty" do
      assert {1, 1} == SourceFile.lsp_position_to_elixir("", {0, 0})
    end

    test "lsp_position_to_elixir single first char" do
      assert {1, 1} == SourceFile.lsp_position_to_elixir("abcde", {0, 0})
    end

    test "lsp_position_to_elixir single line" do
      assert {1, 2} == SourceFile.lsp_position_to_elixir("abcde", {0, 1})
    end

    test "lsp_position_to_elixir single line utf8" do
      assert {1, 2} == SourceFile.lsp_position_to_elixir("🏳️‍🌈abcde", {0, 6})
    end

    test "lsp_position_to_elixir single line index inside high surrogate pair" do
      assert {1, 7} == SourceFile.lsp_position_to_elixir("Hello 🙌 World", {0, 6})
      assert {1, 7} == SourceFile.lsp_position_to_elixir("Hello 🙌 World", {0, 7})
      assert {1, 8} == SourceFile.lsp_position_to_elixir("Hello 🙌 World", {0, 8})
    end

    test "lsp_position_to_elixir single line index inside supplementary variation selector surrogate pair" do
      # Choose a byte ≥ 16 so that the variation selector is in the supplementary range.
      # Byte 20 yields: 0xE0100 + (20 - 16) = 0xE0104.
      #
      # The encoder prepends a base character. Here the base "A" (a BMP character)
      # is encoded in UTF16 as 2 bytes (one code unit). The supplementary variation selector
      # will be encoded in UTF16 as a surrogate pair (4 bytes, or 2 code units).
      encoded = VariationSelectorEncoder.encode("A", <<20>>) <> "B"

      # In UTF16, the string consists of:
      #   • code unit 0: "A"
      #   • code units 1 & 2: variation selector (surrogate pair)
      #   • code unit 3: "B"
      #
      # When converting to UTF8, "A" plus its variation selector form one grapheme cluster.
      # Thus:
      #   - Position {0, 1} (offset covering just "A") results in 1 complete grapheme → column = 1 + 1 = 2.
      #   - Position {0, 2} (offset inside the surrogate pair) is clamped back to include only "A" → column 2.
      #   - Position {0, 3} (offset covering the full surrogate pair) still forms one grapheme → column 2.
      #   - Position {0, 4} (offset covering the full combined grapheme plus "B") gives 2 graphemes → column 3.
      pos1 = SourceFile.lsp_position_to_elixir(encoded, {0, 1})
      pos2 = SourceFile.lsp_position_to_elixir(encoded, {0, 2})
      pos3 = SourceFile.lsp_position_to_elixir(encoded, {0, 3})
      pos4 = SourceFile.lsp_position_to_elixir(encoded, {0, 4})

      assert pos1 == {1, 2}
      assert pos2 == {1, 2}
      assert pos3 == {1, 2}
      assert pos4 == {1, 3}
    end

    test "lsp_position_to_elixir with BMP variation selector" do
      # Choose a byte < 16 so that the variation selector is in the BMP.
      # Byte 10 yields: 0xFE00 + 10 = 0xFE0A.
      # Both "A" and the variation selector will be encoded as single UTF16 code units.
      encoded = VariationSelectorEncoder.encode("A", <<10>>) <> "B"

      # UTF16 breakdown:
      #   • code unit 0: "A"
      #   • code unit 1: variation selector
      #   • code unit 2: "B"
      #
      # "A" and its BMP variation selector form one grapheme cluster.
      pos1 = SourceFile.lsp_position_to_elixir(encoded, {0, 1})
      pos2 = SourceFile.lsp_position_to_elixir(encoded, {0, 2})
      pos3 = SourceFile.lsp_position_to_elixir(encoded, {0, 3})

      # In UTF8, since the BMP variation selector is a combining mark, "A" and its selector form one grapheme.
      # - A partial covering just "A" (position {0,1}) yields one grapheme → column = 2.
      # - A partial covering "A" and the variation selector (position {0,2}) is still one grapheme → column 2.
      # - Only when "B" is also included (position {0,3}) does the grapheme count increase → column 3.

      assert pos1 == {1, 2}
      assert pos2 == {1, 2}
      assert pos3 == {1, 3}
    end

    test "lsp_position_to_elixir multi line" do
      assert {2, 2} == SourceFile.lsp_position_to_elixir("abcde\n1234", {1, 1})
    end

    # This is not specified in LSP but some clients fail to synchronize text properly
    test "lsp_position_to_elixir single line before line start" do
      assert {1, 1} == SourceFile.lsp_position_to_elixir("abcde", {0, -1})
    end

    # LSP spec 3.17 https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#position
    # position character If the character value is greater than the line length it defaults back to the line length
    test "lsp_position_to_elixir single line after line end" do
      assert {1, 6} == SourceFile.lsp_position_to_elixir("abcde", {0, 15})
      assert {1, 1} == SourceFile.lsp_position_to_elixir("", {0, 15})
    end

    # This is not specified in LSP but some clients fail to synchronize text properly
    test "lsp_position_to_elixir multi line before first line" do
      assert {1, 1} == SourceFile.lsp_position_to_elixir("abcde\n1234", {-1, 2})
    end

    # This is not specified in LSP but some clients fail to synchronize text properly
    test "lsp_position_to_elixir multi line after last line" do
      assert {2, 5} == SourceFile.lsp_position_to_elixir("abcde\n1234", {8, 2})
    end

    test "elixir_position_to_lsp empty" do
      assert {0, 0} == SourceFile.elixir_position_to_lsp("", {1, 1})
    end

    test "elixir_position_to_lsp single line first char" do
      assert {0, 0} == SourceFile.elixir_position_to_lsp("abcde", {1, 1})
    end

    test "elixir_position_to_lsp single line" do
      assert {0, 1} == SourceFile.elixir_position_to_lsp("abcde", {1, 2})
    end

    test "elixir_position_to_lsp single line utf8" do
      assert {0, 6} == SourceFile.elixir_position_to_lsp("🏳️‍🌈abcde", {1, 2})
    end

    test "elixir_position_to_lsp multi line" do
      assert {1, 1} == SourceFile.elixir_position_to_lsp("abcde\n1234", {2, 2})
    end

    # This is not specified in LSP but some clients fail to synchronize text properly
    test "elixir_position_to_lsp single line before line start" do
      assert {0, 0} == SourceFile.elixir_position_to_lsp("abcde", {1, -1})
      assert {0, 0} == SourceFile.elixir_position_to_lsp("abcde", {1, 0})
    end

    # LSP spec 3.17 https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#position
    # position character If the character value is greater than the line length it defaults back to the line length
    test "elixir_position_to_lsp single line after line end" do
      assert {0, 5} == SourceFile.elixir_position_to_lsp("abcde", {1, 15})
      assert {0, 0} == SourceFile.elixir_position_to_lsp("", {1, 15})
    end

    # This is not specified in LSP but some clients fail to synchronize text properly
    test "elixir_position_to_lsp multi line before first line" do
      assert {0, 0} == SourceFile.elixir_position_to_lsp("abcde\n1234", {-1, 2})
      assert {0, 0} == SourceFile.elixir_position_to_lsp("abcde\n1234", {0, 2})
    end

    # This is not specified in LSP but some clients fail to synchronize text properly
    test "elixir_position_to_lsp multi line after last line" do
      assert {1, 4} == SourceFile.elixir_position_to_lsp("abcde\n1234", {8, 2})
    end

    test "sanity check" do
      text = "aąłsd🏳️‍🌈abcde"

      for i <- 0..String.length(text) do
        elixir_pos = {1, i + 1}
        lsp_pos = SourceFile.elixir_position_to_lsp(text, elixir_pos)

        assert elixir_pos == SourceFile.lsp_position_to_elixir(text, lsp_pos)
      end
    end
  end
end
