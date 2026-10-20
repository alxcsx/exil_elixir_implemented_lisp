defmodule Core.EnvTest do
  use ExUnit.Case, async: true
  alias Core.Env

  describe "Env Instatiation" do
    test "Empty Env" do
      env = Env.new()
      assert env.vars == %{}
      assert env.types == %{}
      assert env.macros == %{}
      assert env.vars == %{}
      assert env.parent == nil
    end

    test "Nested Env" do
      parent = Env.new()
      child = Env.new(parent)
      assert child.parent == parent
    end
  end

  describe "Variable Lookup" do
    test "Find on Current Scope" do
      env = %{Env.new() | vars: %{"x" => 10}}
      assert Env.get_var(env, "x") == 10
    end

    test "Find on Parent Scope" do
      parent = %{Env.new() | vars: %{"x" => 10}}
      child = Env.new(parent)
      assert Env.get_var(child, "x") == 10
    end

    test "Parent Scope Shadowing" do
      parent = %{Env.new() | vars: %{"x" => 10}}
      child = %{Env.new(parent) | vars: %{"x" => 20}}

      assert Env.get_var(child, "x") == 20
      assert Env.get_var(parent, "x") == 10
    end

    test "Return Nil for non-existing keys" do
      env = Env.new()
      assert Env.get_var(env, "misisng") == nil
    end

    test "Return Nil for nil env" do
      assert Env.get_var(nil, "abacate") == nil
    end
  end

  describe "Module Namespacing" do
    test "same name in two modules does not collide" do
      foo = %{Env.new() | current_module: :foo} |> Env.put_macro(:m, :foo_macro)
      bar = %{Env.new(foo) | current_module: :bar} |> Env.put_macro(:m, :bar_macro)

      assert Env.get_macro(foo, :m) == :foo_macro
      assert Env.get_macro(bar, :m) == :bar_macro
    end

    test "child env inherits the current module" do
      env = %{Env.new() | current_module: :foo}
      assert Env.new(env).current_module == :foo
    end
  end

  describe "Imports" do
    test "import exposes another module's macros unqualified" do
      foo = %{Env.new() | current_module: :foo} |> Env.put_macro(:m, :foo_macro)
      bar = %{Env.new(foo) | current_module: :bar} |> Env.import_module(:foo)

      assert Env.has_macro?(bar, :m)
      assert Env.get_macro(bar, :m) == :foo_macro
    end

    test "local definition shadows import" do
      foo = %{Env.new() | current_module: :foo} |> Env.put_macro(:m, :foo_macro)

      bar =
        %{Env.new(foo) | current_module: :bar}
        |> Env.import_module(:foo)
        |> Env.put_macro(:m, :bar_macro)

      assert Env.get_macro(bar, :m) == :bar_macro
    end

    test "import is the only path to another module's defs" do
      foo = %{Env.new() | current_module: :foo} |> Env.put_def(:inc, :inc_binding)
      bar = %{Env.new(foo) | current_module: :bar}

      assert Env.get_var(bar, :inc) == nil
      assert Env.get_var(Env.import_module(bar, :foo), :inc) == :inc_binding
      assert Env.get_def(Env.import_module(bar, :foo), :inc) == :inc_binding
    end

    test "import as binds a prefix without bringing unqualified names" do
      foo = %{Env.new() | current_module: :foo} |> Env.put_def(:inc, :inc_binding)
      bar = %{Env.new(foo) | current_module: :bar} |> Env.alias_module(:f, :foo)

      assert Env.get_var(bar, :"f/inc") == :inc_binding
      assert Env.get_var(bar, :inc) == nil
    end

    test "prefix alias points at an opaque multi-segment module name" do
      math = %{Env.new() | current_module: :"std/math"} |> Env.put_def(:sum, :sum_binding)
      main = %{Env.new(math) | current_module: :main} |> Env.alias_module(:m, :"std/math")

      assert Env.get_def(main, :"m/sum") == :sum_binding
    end
  end
end
