module gen

import (
	strings
	v.ast
	v.table
	v.depgraph
	term
)

struct Gen {
	out            strings.Builder
	typedefs       strings.Builder
	definitions    strings.Builder // typedefs, defines etc (everything that goes to the top of the file)
	table          &table.Table
mut:
	fn_decl        &ast.FnDecl // pointer to the FnDecl we are currently inside otherwise 0
	tmp_count      int
	varaidic_args  map[string]int
	is_c_call      bool // e.g. `C.printf("v")`
	is_assign_expr bool // inside left part of assign expr (for array_set(), etc)
	is_array_set   bool
	is_amp         bool // for `&Foo{}` to merge PrefixExpr `&` and StructInit `Foo{}`; also for `&byte(0)` etc
	optionals      []string // to avoid duplicates TODO perf, use map
}

pub fn cgen(files []ast.File, table &table.Table) string {
	println('start cgen2')
	mut g := Gen{
		out: strings.new_builder(100)
		typedefs: strings.new_builder(100)
		definitions: strings.new_builder(100)
		table: table
		fn_decl: 0
	}
	g.init()
	for file in files {
		g.stmts(file.stmts)
	}
	g.write_variadic_types()
	return g.typedefs.str() + g.definitions.str() + g.out.str()
}

pub fn (g mut Gen) init() {
	g.definitions.writeln('// Generated by the V compiler')
	g.definitions.writeln('#include <inttypes.h>') // int64_t etc
	g.definitions.writeln(c_builtin_types)
	g.definitions.writeln(c_headers)
	g.write_builtin_types()
	g.write_typedef_types()
	g.write_sorted_types()
	g.write_multi_return_types()
	g.definitions.writeln('// end of definitions #endif')
}

// V type to C type
pub fn (g mut Gen) typ(t table.Type) string {
	nr_muls := table.type_nr_muls(t)
	sym := g.table.get_type_symbol(t)
	mut styp := sym.name.replace_each(['.', '__'])
	if nr_muls > 0 {
		styp += strings.repeat(`*`, nr_muls)
	}
	if styp.starts_with('C__') {
		styp = styp[3..]
	}
	if styp in ['stat', 'dirent*', 'tm'] {
		// TODO perf and other C structs
		styp = 'struct $styp'
	}
	if table.type_is_optional(t) {
		styp = 'Option_' + styp
		if !(styp in g.optionals) {
			g.definitions.writeln('typedef Option $styp;')
			g.optionals << styp
		}
	}
	return styp
}

/*
pub fn (g &Gen) styp(t string) string {
	return t.replace_each(['.', '__'])
}
*/

//
pub fn (g mut Gen) write_typedef_types() {
	for typ in g.table.types {
		match typ.kind {
			.alias {
				parent := &g.table.types[typ.parent_idx]
				styp := typ.name.replace('.', '__')
				parent_styp := parent.name.replace('.', '__')
				g.definitions.writeln('typedef $parent_styp $styp;')
			}
			.array {
				styp := typ.name.replace('.', '__')
				g.definitions.writeln('typedef array $styp;')
			}
			.array_fixed {
				styp := typ.name.replace('.', '__')
				// array_fixed_char_300 => char x[300]
				mut fixed := styp[12..]
				len := styp.after('_')
				fixed = fixed[..fixed.len - len.len - 1]
				g.definitions.writeln('typedef $fixed $styp [$len];')
			}
			.map {
				styp := typ.name.replace('.', '__')
				g.definitions.writeln('typedef map $styp;')
			}
			.function {
				info := typ.info as table.FnType
				func := info.func
				if !info.has_decl && !info.is_anon {
					fn_name := func.name.replace('.', '__')
					g.definitions.write('typedef ${g.typ(func.return_type)} (*$fn_name)(')
					for i,arg in func.args {
						g.definitions.write(g.typ(arg.typ))
						if i < func.args.len - 1 {
							g.definitions.write(',')
						}
					}
					g.definitions.writeln(');')
				}
			}
			else {
				continue
			}
	}
	}
}

pub fn (g mut Gen) write_multi_return_types() {
	g.definitions.writeln('// multi return structs')
	for typ in g.table.types {
		// sym := g.table.get_type_symbol(typ)
		if typ.kind != .multi_return {
			continue
		}
		name := typ.name.replace('.', '__')
		info := typ.info as table.MultiReturn
		g.definitions.writeln('typedef struct {')
		// TODO copy pasta StructDecl
		// for field in struct_info.fields {
		for i, mr_typ in info.types {
			type_name := g.typ(mr_typ)
			g.definitions.writeln('\t$type_name arg${i};')
		}
		g.definitions.writeln('} $name;\n')
		// g.typedefs.writeln('typedef struct $name $name;')
	}
}

pub fn (g mut Gen) write_variadic_types() {
	if g.varaidic_args.size > 0 {
		g.definitions.writeln('// variadic structs')
	}
	for type_str, arg_len in g.varaidic_args {
		typ := table.Type(type_str.int())
		type_name := g.typ(typ)
		struct_name := 'varg_' + type_name.replace('*', '_ptr')
		g.definitions.writeln('struct $struct_name {')
		g.definitions.writeln('\tint len;')
		g.definitions.writeln('\t$type_name args[$arg_len];')
		g.definitions.writeln('};\n')
		g.typedefs.writeln('typedef struct $struct_name $struct_name;')
	}
}

pub fn (g &Gen) save() {}

pub fn (g mut Gen) write(s string) {
	g.out.write(s)
}

pub fn (g mut Gen) writeln(s string) {
	g.out.writeln(s)
}

pub fn (g mut Gen) new_tmp_var() string {
	g.tmp_count++
	return 'tmp$g.tmp_count'
}

pub fn (g mut Gen) reset_tmp_count() {
	g.tmp_count = 0
}

fn (g mut Gen) stmts(stmts []ast.Stmt) {
	for stmt in stmts {
		g.stmt(stmt)
		g.writeln('')
	}
}

fn (g mut Gen) stmt(node ast.Stmt) {
	// println('cgen.stmt()')
	// g.writeln('//// stmt start')
	match node {
		ast.AssignStmt {
			g.gen_assign_stmt(it)
		}
		ast.AssertStmt {
			g.writeln('// assert')
			// TODO
		}
		ast.Attr {
			g.writeln('//[$it.name]')
		}
		ast.BranchStmt {
			// continue or break
			g.write(it.tok.kind.str())
			g.writeln(';')
		}
		ast.ConstDecl {
			g.const_decl(it)
		}
		ast.CompIf {
			// TODO
			g.writeln('//#ifdef ')
			g.expr(it.cond)
			g.stmts(it.stmts)
			g.writeln('//#endif')
		}
		ast.DeferStmt {
			g.writeln('// defer')
		}
		ast.EnumDecl {
			g.writeln('//')
			/*
			name := it.name.replace('.', '__')
			g.definitions.writeln('typedef enum {')
			for i, val in it.vals {
				g.definitions.writeln('\t${name}_$val, // $i')
			}
			g.definitions.writeln('} $name;')
			*/

		}
		ast.ExprStmt {
			g.expr(it.expr)
			match it.expr {
				// no ; after an if expression
				ast.IfExpr {}
				else {
					g.writeln(';')
				}
	}
		}
		ast.FnDecl {
			g.fn_decl = it // &it
			g.gen_fn_decl(it)
		}
		ast.ForCStmt {
			g.write('for (')
			if !it.has_init {
				g.write('; ')
			}
			else {
				g.stmt(it.init)
			}
			g.expr(it.cond)
			g.write('; ')
			// g.stmt(it.inc)
			g.expr(it.inc)
			g.writeln(') {')
			for stmt in it.stmts {
				g.stmt(stmt)
			}
			g.writeln('}')
		}
		ast.ForInStmt {
			if it.is_range {
				i := g.new_tmp_var()
				g.write('for (int $i = ')
				g.expr(it.cond)
				g.write('; $i < ')
				g.expr(it.high)
				g.writeln('; $i++) { ')
				// g.stmts(it.stmts) TODO
				g.writeln('}')
			}
		}
		ast.ForStmt {
			g.write('while (')
			if it.is_inf {
				g.write('1')
			}
			else {
				g.expr(it.cond)
			}
			g.writeln(') {')
			for stmt in it.stmts {
				g.stmt(stmt)
			}
			g.writeln('}')
		}
		ast.GlobalDecl {
			styp := g.typ(it.typ)
			g.definitions.writeln('$styp $it.name; // global')
		}
		ast.GotoLabel {
			g.writeln('$it.name:')
		}
		ast.HashStmt {
			// #include etc
			typ := it.val.all_before(' ')
			if typ in ['include', 'define'] {
				g.definitions.writeln('#$it.val')
			}
		}
		ast.Import {}
		ast.Return {
			g.return_statement(it)
		}
		ast.StructDecl {
			name := it.name.replace('.', '__')
			// g.writeln('typedef struct {')
			// for field in it.fields {
			// field_type_sym := g.table.get_type_symbol(field.typ)
			// g.writeln('\t$field_type_sym.name $field.name;')
			// }
			// g.writeln('} $name;')
			if !it.is_c {
				g.typedefs.writeln('typedef struct $name $name;')
			}
		}
		ast.TypeDecl {
			g.writeln('// TypeDecl')
		}
		ast.UnsafeStmt {
			g.stmts(it.stmts)
		}
		else {
			verror('cgen.stmt(): unhandled node ' + typeof(node))
		}
	}
}

// use instead of expr() when you need to cast to sum type (can add other casts also)
fn (g mut Gen) expr_with_cast(got_type table.Type, exp_type table.Type, expr ast.Expr) {
	// cast to sum type
	if exp_type != table.void_type && exp_type != 0  && got_type != 0{
		exp_sym := g.table.get_type_symbol(exp_type)
		if exp_sym.kind == .sum_type {
			sum_info := exp_sym.info as table.SumType
			if got_type in sum_info.variants {
				got_styp := g.typ(got_type)
				exp_styp := g.typ(exp_type)
				got_idx := table.type_idx(got_type)
				g.write('/* SUM TYPE CAST */ ($exp_styp) {.obj = memdup(&(${got_styp}[]) {')
				g.expr(expr)
				g.writeln('}, sizeof($got_styp)), .typ = $got_idx};')
			}
		}
	}
	// no cast
	g.expr(expr)
}

fn (g mut Gen) gen_assign_stmt(assign_stmt ast.AssignStmt) {
	// multi return
	// g.write('/*assign*/')
	if assign_stmt.left.len > assign_stmt.right.len {
		mut return_type := table.void_type
		match assign_stmt.right[0] {
			ast.CallExpr {
				return_type = it.return_type
			}
			ast.MethodCallExpr {
				return_type = it.return_type
			}
			else {
				panic('expected call')
			}
	}
		mr_var_name := 'mr_$assign_stmt.pos.pos'
		mr_typ_str := g.typ(return_type)
		g.write('$mr_typ_str $mr_var_name = ')
		g.expr(assign_stmt.right[0])
		g.writeln(';')
		for i, ident in assign_stmt.left {
			if ident.kind == .blank_ident {
				continue
			}
			ident_var_info := ident.var_info()
			styp := g.typ(ident_var_info.typ)
			if assign_stmt.op == .decl_assign {
				g.write('$styp ')
			}
			g.expr(ident)
			g.writeln(' = ${mr_var_name}.arg$i;')
		}
	}
	// `a := 1` | `a,b := 1,2`
	else {
		for i, ident in assign_stmt.left {
			val := assign_stmt.right[i]
			ident_var_info := ident.var_info()
			styp := g.typ(ident_var_info.typ)
			if ident.kind == .blank_ident {
				is_call := match val {
					ast.CallExpr{
						true
					}
					ast.MethodCallExpr{
						true
					}
					else {
						false}
	}
				if is_call {
					g.expr(val)
				}
				else {
					g.write('{$styp _ = ')
					g.expr(val)
					g.write('}')
				}
			}
			else {
				mut is_fixed_array_init := false
				match val {
					ast.ArrayInit {
						is_fixed_array_init = g.table.get_type_symbol(it.typ).kind == .array_fixed
					}
					else {}
	}
				is_decl := assign_stmt.op == .decl_assign
				if is_decl {
					g.write('$styp ')
				}
				g.expr(ident)
				if !is_fixed_array_init {
					g.write(' = ')
					if !is_decl {
						g.expr_with_cast(assign_stmt.left_types[i], ident_var_info.typ, val)
					} else {
						g.expr(val)
					}
				}
			}
			g.writeln(';')
		}
	}
}

fn (g mut Gen) gen_fn_decl(it ast.FnDecl) {
	if it.is_c || it.name == 'malloc' || it.no_body {
		return
	}
	g.reset_tmp_count()
	is_main := it.name == 'main'
	if is_main {
		g.write('int ${it.name}(')
	}
	else {
		mut name := it.name
		if it.is_method {
			name = g.table.get_type_symbol(it.receiver.typ).name + '_' + name
		}
		name = name.replace('.', '__')
		if name.starts_with('_op_') {
			name = op_to_fn_name(name)
		}
		if name == 'exit' {
			name = 'v_exit'
		}
		// type_name := g.table.type_to_str(it.return_type)
		type_name := g.typ(it.return_type)
		g.write('$type_name ${name}(')
		g.definitions.write('$type_name ${name}(')
	}
	// Receiver is the first argument
	/*
	if it.is_method {
		mut styp := g.typ(it.receiver.typ)
		// if table.type_nr_muls(it.receiver.typ) > 0 {
		// if it.rec_mut {
		// styp += '*'
		// }
		g.write('$styp $it.receiver.name ')
		// TODO mut
		g.definitions.write('$styp $it.receiver.name')
		if it.args.len > 0 {
			g.write(', ')
			g.definitions.write(', ')
		}
	}
	*/
	//
	g.fn_args(it.args, it.is_variadic)
	g.writeln(') { ')
	if !is_main {
		g.definitions.writeln(');')
	}
	for stmt in it.stmts {
		// g.write('\t')
		g.stmt(stmt)
	}
	if is_main {
		g.writeln('return 0;')
	}
	g.writeln('}')
	g.fn_decl = 0
}

fn (g mut Gen) fn_args(args []table.Arg, is_variadic bool) {
	no_names := args.len > 0 && args[0].name == 'arg_1'
	for i, arg in args {
		arg_type_sym := g.table.get_type_symbol(arg.typ)
		mut arg_type_name := g.typ(arg.typ) // arg_type_sym.name.replace('.', '__')
		is_varg := i == args.len - 1 && is_variadic
		if is_varg {
			g.varaidic_args[int(arg.typ).str()] = 0
			arg_type_name = 'varg_' + g.typ(arg.typ).replace('*', '_ptr')
		}
		if arg_type_sym.kind == .function {
			info := arg_type_sym.info as table.FnType
			func := info.func
			g.write('${g.typ(func.return_type)} (*$arg.name)(')
			g.definitions.write('${g.typ(func.return_type)} (*$arg.name)(')
			g.fn_args(func.args, func.is_variadic)
			g.write(')')
			g.definitions.write(')')
		}
		else if no_names {
			g.write(arg_type_name)
			g.definitions.write(arg_type_name)
		}
		else {
			mut nr_muls := table.type_nr_muls(arg.typ)
			s := arg_type_name + ' ' + arg.name
			if arg.is_mut {
				// mut arg needs one *
				nr_muls = 1
			}
			// if nr_muls > 0 && !is_varg {
			// s = arg_type_name + strings.repeat(`*`, nr_muls) + ' ' + arg.name
			// }
			g.write(s)
			g.definitions.write(s)
		}
		if i < args.len - 1 {
			g.write(', ')
			g.definitions.write(', ')
		}
	}
}

fn (g mut Gen) expr(node ast.Expr) {
	// println('cgen expr() line_nr=$node.pos.line_nr')
	match node {
		ast.ArrayInit {
			type_sym := g.table.get_type_symbol(it.typ)
			if type_sym.kind != .array_fixed {
				elem_sym := g.table.get_type_symbol(it.elem_type)
				elem_type_str := g.typ(it.elem_type)
				g.write('new_array_from_c_array($it.exprs.len, $it.exprs.len, sizeof($elem_type_str), ')
				g.writeln('($elem_type_str[]){\t')
				for expr in it.exprs {
					g.expr(expr)
					g.write(', ')
				}
				g.write('\n})')
			}
			else {}
		}
		ast.AsCast {
			g.write('/* as */')
		}
		ast.AssignExpr {
			g.is_assign_expr = true
			mut str_add := false
			if it.left_type == table.string_type_idx && it.op == .plus_assign {
				// str += str2 => `str = string_add(str, str2)`
				g.expr(it.left)
				g.write(' = string_add(')
				str_add = true
			}
			g.expr(it.left)
			// arr[i] = val => `array_set(arr, i, val)`, not `array_get(arr, i) = val`
			if !g.is_array_set && !str_add {
				g.write(' $it.op.str() ')
			}
			else if str_add {
				g.write(', ')
			}
			g.is_assign_expr = false
			g.expr_with_cast(it.right_type, it.left_type, it.val)
			if g.is_array_set {
				g.write(' })')
				g.is_array_set = false
			}
			else if str_add {
				g.write(')')
			}
		}
		ast.Assoc {
			g.write('/* assoc */')
		}
		ast.BoolLiteral {
			g.write(it.val.str())
		}
		ast.CallExpr {
			mut name := it.name.replace('.', '__')
			if name == 'exit' {
				name = 'v_exit'
			}
			if it.is_c {
				// Skip "C__"
				g.is_c_call = true
				name = name[3..]
			}
			g.write('${name}(')
			if name == 'println' && it.args[0].typ != table.string_type_idx {
				// `println(int_str(10))`
				sym := g.table.get_type_symbol(it.args[0].typ)
				g.write('${sym.name}_str(')
				g.expr(it.args[0].expr)
				g.write('))')
			}
			else {
				g.call_args(it.args)
				g.write(')')
			}
			g.is_c_call = false
		}
		ast.CastExpr {
			// g.write('/*cast*/')
			if g.is_amp {
				// &Foo(0) => ((Foo*)0)
				g.out.go_back(1)
			}
			if it.typ == table.string_type_idx {
				// `tos(str, len)`, `tos2(str)`
				if it.has_arg {
					g.write('tos(')
				}
				else {
					g.write('tos2(')
				}
				g.expr(it.expr)
				sym := g.table.get_type_symbol(it.expr_type)
				if sym.kind == .array {
					// if we are casting an array, we need to add `.data`
					g.write('.data')
				}
				if it.has_arg {
					// len argument
					g.write(', ')
					g.expr(it.arg)
				}
				g.write(')')
			}
			else {
				// styp := g.table.type_to_str(it.typ)
				styp := g.typ(it.typ)
				// g.write('($styp)(')
				g.write('(($styp)(')
				// if g.is_amp {
				// g.write('*')
				// }
				// g.write(')(')
				g.expr(it.expr)
				g.write('))')
			}
		}
		ast.CharLiteral {
			g.write("'$it.val'")
		}
		ast.EnumVal {
			// g.write('/*EnumVal*/${it.mod}${it.enum_name}_$it.val')
			g.write(g.typ(it.typ))
			g.write('_$it.val')
		}
		ast.FloatLiteral {
			g.write(it.val)
		}
		ast.Ident {
			g.ident(it)
		}
		ast.IfExpr {
			// If expression? Assign the value to a temp var.
			// Previously ?: was used, but it's too unreliable.
			type_sym := g.table.get_type_symbol(it.typ)
			mut tmp := ''
			if type_sym.kind != .void {
				tmp = g.new_tmp_var()
				// g.writeln('$ti.name $tmp;')
			}
			// one line ?:
			// TODO clean this up once `is` is supported
			if it.stmts.len == 1 && it.else_stmts.len == 1 && type_sym.kind != .void {
				cond := it.cond
				stmt1 := it.stmts[0]
				else_stmt1 := it.else_stmts[0]
				match stmt1 {
					ast.ExprStmt {
						g.expr(cond)
						g.write(' ? ')
						expr_stmt := stmt1 as ast.ExprStmt
						g.expr(expr_stmt.expr)
						g.write(' : ')
						g.stmt(else_stmt1)
					}
					else {}
	}
			}
			else {
				g.write('if (')
				g.expr(it.cond)
				g.writeln(') {')
				for i, stmt in it.stmts {
					// Assign ret value
					if i == it.stmts.len - 1 && type_sym.kind != .void {}
					// g.writeln('$tmp =')
					g.stmt(stmt)
				}
				g.writeln('}')
				if it.else_stmts.len > 0 {
					g.writeln('else { ')
					for stmt in it.else_stmts {
						g.stmt(stmt)
					}
					g.writeln('}')
				}
			}
		}
		ast.IfGuardExpr {
			g.write('/* guard */')
		}
		ast.IndexExpr {
			g.index_expr(it)
		}
		ast.InfixExpr {
			g.infix_expr(it)
		}
		ast.IntegerLiteral {
			g.write(it.val.int().str())
		}
		ast.MatchExpr {
			g.match_expr(it)
		}
		ast.MapInit {
			key_typ_sym := g.table.get_type_symbol(it.key_type)
			value_typ_sym := g.table.get_type_symbol(it.value_type)
			key_typ_str := key_typ_sym.name.replace('.', '__')
			value_typ_str := value_typ_sym.name.replace('.', '__')
			size := it.vals.len
			if size > 0 {
				g.write('new_map_init($size, sizeof($value_typ_str), (${key_typ_str}[$size]){')
				for expr in it.keys {
					g.expr(expr)
					g.write(', ')
				}
				g.write('}, (${value_typ_str}[$size]){')
				for expr in it.vals {
					g.expr(expr)
					g.write(', ')
				}
				g.write('})')
			}
			else {
				g.write('new_map(1, sizeof($value_typ_str))')
			}
		}
		ast.MethodCallExpr {
			mut receiver_name := 'TODO'
			// TODO: there are still due to unchecked exprs (opt/some fn arg)
			if it.expr_type != 0 {
				typ_sym := g.table.get_type_symbol(it.expr_type)
				// rec_sym := g.table.get_type_symbol(it.receiver_type)
				receiver_name = typ_sym.name
				if typ_sym.kind == .array && it.name in
				// TODO performance, detect `array` method differently
				['repeat', 'sort_with_compare', 'free', 'push_many', 'trim', 'first', 'clone'] {
					// && rec_sym.name == 'array' {
					// && rec_sym.name == 'array' && receiver_name.starts_with('array') {
					// `array_byte_clone` => `array_clone`
					receiver_name = 'array'
				}
			}
			name := '${receiver_name}_$it.name'.replace('.', '__')
			// if it.receiver_type != 0 {
			// g.write('/*${g.typ(it.receiver_type)}*/')
			// g.write('/*expr_type=${g.typ(it.expr_type)} rec type=${g.typ(it.receiver_type)}*/')
			// }
			g.write('${name}(')
			if table.type_is_ptr(it.receiver_type) && !table.type_is_ptr(it.expr_type) {
				// The receiver is a reference, but the caller provided a value
				// Add `&` automatically.
				// TODO same logic in call_args()
				g.write('&')
			}
			else if !table.type_is_ptr(it.receiver_type) && table.type_is_ptr(it.expr_type) {
				g.write('/*rec*/*')
			}
			g.expr(it.expr)
			if it.args.len > 0 {
				g.write(', ')
			}
			// /////////
			/*
			if name.contains('subkeys') {
				println('call_args $name $it.arg_types.len')
				for t in it.arg_types {
					sym := g.table.get_type_symbol(t)
					print('$sym.name ')
				}
				println('')
			}
			*/
			// ///////
			g.call_args(it.args)
			g.write(')')
		}
		ast.None {
			g.write('opt_none()')
		}
		ast.ParExpr {
			g.write('(')
			g.expr(it.expr)
			g.write(')')
		}
		ast.PostfixExpr {
			g.expr(it.expr)
			g.write(it.op.str())
		}
		ast.PrefixExpr {
			if it.op == .amp {
				g.is_amp = true
			}
			// g.write('/*pref*/')
			g.write(it.op.str())
			g.expr(it.right)
			g.is_amp = false
		}
		/*
		ast.UnaryExpr {
			// probably not :D
			if it.op in [.inc, .dec] {
				g.expr(it.left)
				g.write(it.op.str())
			}
			else {
				g.write(it.op.str())
				g.expr(it.left)
			}
		}
		*/

		ast.SizeOf {
			g.write('sizeof($it.type_name)')
		}
		ast.StringLiteral {
			// In C calls we have to generate C strings
			// `C.printf("hi")` => `printf("hi");`
			escaped_val := it.val.replace_each(['"', '\\"',
			'\r\n', '\\n',
			'\n', '\\n'])
			if g.is_c_call {
				g.write('"$escaped_val"')
			}
			else {
				g.write('tos3("$escaped_val")')
			}
		}
		// `user := User{name: 'Bob'}`
		ast.StructInit {
			styp := g.typ(it.typ)
			if g.is_amp {
				g.out.go_back(1) // delete the & already generated in `prefix_expr()
				g.write('($styp*)memdup(&($styp){')
			}
			else {
				g.writeln('($styp){')
			}
			for i, field in it.fields {
				g.write('\t.$field = ')
				g.expr(it.exprs[i])
				g.writeln(', ')
			}
			if it.fields.len == 0 {
				g.write('0')
			}
			g.write('}')
			if g.is_amp {
				g.write(', sizeof($styp))')
			}
		}
		ast.SelectorExpr {
			g.expr(it.expr)
			// if table.type_nr_muls(it.expr_type) > 0 {
			if table.type_is_ptr(it.expr_type) {
				g.write('->')
			}
			else {
				// g.write('. /*typ=  $it.expr_type */') // ${g.typ(it.expr_type)} /')
				g.write('.')
			}
			if it.expr_type == 0 {
				verror('cgen: SelectorExpr typ=0 field=$it.field')
			}
			g.write(it.field)
		}
		ast.Type {
			// match sum Type
			// g.write('/* Type */')
			g.write('_type_idx_')
			g.write(g.typ(it.typ))
		}
		else {
			// #printf("node=%d\n", node.typ);
			println(term.red('cgen.expr(): bad node ' + typeof(node)))
		}
	}
}

fn (g mut Gen) infix_expr(node ast.InfixExpr) {
	// g.write('/*infix*/')
	// if it.left_type == table.string_type_idx {
	// g.write('/*$node.left_type str*/')
	// }
	// string + string, string == string etc
	if node.left_type == table.string_type_idx && node.op != .key_in {
		fn_name := match node.op {
			.plus{
				'string_add('
			}
			.eq{
				'string_eq('
			}
			.ne{
				'string_ne('
			}
			.lt{
				'string_lt('
			}
			.le{
				'string_le('
			}
			.gt{
				'string_gt('
			}
			.ge{
				'string_ge('
			}
			else {
				'/*node error*/'}
	}
		g.write(fn_name)
		g.expr(node.left)
		g.write(', ')
		g.expr(node.right)
		g.write(')')
	}
	else if node.op == .key_in {
		styp := g.typ(node.left_type)
		g.write('_IN($styp, ')
		g.expr(node.left)
		g.write(', ')
		g.expr(node.right)
		g.write(')')
	}
	// arr << val
	else if node.op == .left_shift && g.table.get_type_symbol(node.left_type).kind == .array {
		tmp := g.new_tmp_var()
		sym := g.table.get_type_symbol(node.left_type)
		right_sym := g.table.get_type_symbol(node.right_type)
		if right_sym.kind == .array {
			// push an array => PUSH_MANY
			g.write('_PUSH_MANY(&')
			g.expr_with_cast(node.right_type, node.left_type, node.left)
			g.write(', (')
			g.expr(node.right)
			styp := g.typ(node.left_type)
			g.write('), $tmp, $styp)')
		}
		else {
			// push a single element
			info := sym.info as table.Array
			elem_type_str := g.typ(info.elem_type)
			// g.write('array_push(&')
			g.write('_PUSH(&')
			g.expr_with_cast(node.right_type, info.elem_type, node.left)
			g.write(', (')
			g.expr(node.right)
			g.write('), $tmp, $elem_type_str)')
		}
	}
	else {
		// if node.op == .dot {
		// println('!! dot')
		// }
		g.expr(node.left)
		g.write(' $node.op.str() ')
		g.expr(node.right)
	}
}

fn (g mut Gen) match_expr(node ast.MatchExpr) {
	// println('match expr typ=$it.expr_type')
	// TODO
	if node.expr_type == 0 {
		g.writeln('// match 0')
		return
	}
	type_sym := g.table.get_type_symbol(node.expr_type)
	mut tmp := ''
	if type_sym.kind != .void {
		tmp = g.new_tmp_var()
	}
	//styp := g.typ(node.expr_type)
	//g.write('$styp $tmp = ')
	//g.expr(node.cond)
	//g.writeln(';') // $it.blocks.len')
	// mut sum_type_str = ''
	for j, branch in node.branches {
		if j == node.branches.len - 1 {
			// last block is an `else{}`
			g.writeln('else {')
		}
		else {
			if j > 0 {
				g.write('else ')
			}
			g.write('if (')
			for i, expr in branch.exprs {
				if node.is_sum_type {
					g.expr(node.cond )
					g.write('.typ == ')
					//g.write('${tmp}.typ == ')
					// sum_type_str
				}
				else if type_sym.kind == .string {
					g.write('string_eq(')
					//
g.expr(node.cond)
g.write(', ')
					//g.write('string_eq($tmp, ')
				}
				else {
					g.expr(node.cond)
					g.write(' == ')
					//g.write('$tmp == ')
				}
				g.expr(expr)
				if type_sym.kind == .string {
					g.write(')')
				}
				if i < branch.exprs.len - 1 {
					g.write(' || ')
				}
			}
			g.writeln(') {')
		}
		if node.is_sum_type && branch.exprs.len > 0 {
			// The first node in expr is an ast.Type
			// Use it to generate `it` variable.
			fe := branch.exprs[0]
			match fe {
				ast.Type {
					it_type := g.typ(it.typ)
					g.writeln('$it_type* it = ($it_type*)${tmp}.obj; // ST it')
				}
				else {
					verror('match sum type')
				}
	}
		}
		g.stmts(branch.stmts)
		g.writeln('}')
	}
}

fn (g mut Gen) ident(node ast.Ident) {
	name := node.name.replace('.', '__')
	if name.starts_with('C__') {
		g.write(name[3..])
	}
	else {
		// TODO `is`
		match node.info {
			ast.IdentVar {
				if it.is_optional {
					g.write('/*opt*/')
					styp := g.typ(it.typ)[7..] // Option_int => int TODO perf?
					g.write('(*($styp*)${name}.data)')
					return
				}
			}
			else {}
	}
		g.write(name)
	}
}

fn (g mut Gen) index_expr(node ast.IndexExpr) {
	// TODO else doesn't work with sum types
	mut is_range := false
	match node.index {
		ast.RangeExpr {
			// TODO should never be 0
			if node.container_type != 0 {
				sym := g.table.get_type_symbol(node.container_type)
				is_range = true
				if sym.kind == .string {
					g.write('string_substr(')
				}
				else if sym.kind == .array {
					g.write('array_slice(')
				}
			}
			g.expr(node.left)
			g.write(', ')
			if it.has_low {
				g.expr(it.low)
			}
			else {
				g.write('0')
			}
			g.write(', ')
			if it.has_high {
				g.expr(it.high)
			}
			else {
				g.expr(node.left)
				g.write('.len')
			}
			g.write(')')
			return
		}
		else {}
	}
	// if !is_range && node.container_type == 0 {
	// }
	if !is_range && node.container_type != 0 {
		sym := g.table.get_type_symbol(node.container_type)
		if table.type_is_variadic(node.container_type) {
			g.expr(node.left)
			g.write('.args')
			g.write('[')
			g.expr(node.index)
			g.write(']')
		}
		else if sym.kind == .array {
			info := sym.info as table.Array
			elem_type_str := g.typ(info.elem_type)
			if g.is_assign_expr {
				g.is_array_set = true
				g.write('array_set(&')
				g.expr(node.left)
				g.write(', ')
				g.expr(node.index)
				g.write(', &($elem_type_str[]) { ')
			}
			else {
				g.write('(*($elem_type_str*)array_get(')
				g.expr(node.left)
				g.write(', ')
				g.expr(node.index)
				g.write('))')
			}
		}
		else if sym.kind == .string {
			g.write('string_at(')
			g.expr(node.left)
			g.write(', ')
			g.expr(node.index)
			g.write(')')
		}
		else {
			g.expr(node.left)
			g.write('[')
			g.expr(node.index)
			g.write(']')
		}
	}
}

fn (g mut Gen) return_statement(it ast.Return) {
	g.write('return')
	// multiple returns
	if it.exprs.len > 1 {
		typ_sym := g.table.get_type_symbol(g.fn_decl.return_type)
		mr_info := typ_sym.info as table.MultiReturn
		styp := g.typ(g.fn_decl.return_type)
		g.write(' ($styp){')
		for i, expr in it.exprs {
			g.write('.arg$i=')
			g.expr(expr)
			if i < it.exprs.len - 1 {
				g.write(',')
			}
		}
		g.write('}')
	}
	// normal return
	else if it.exprs.len == 1 {
		g.write(' ')
		// `return opt_ok(expr)` for functions that expect an optional
		if table.type_is_optional(g.fn_decl.return_type) {
			mut is_none := false
			mut is_error := false
			match it.exprs[0] {
				ast.None {
					is_none = true
				}
				ast.CallExpr {
					is_error = true // TODO check name 'error'
				}
				else {}
	}
			if !is_none && !is_error {
				styp := g.typ(g.fn_decl.return_type)[7..] // remove 'Option_'
				g.write('opt_ok(& ($styp []) { ')
				g.expr(it.exprs[0])
				g.writeln(' }, sizeof($styp));')
				return
			}
			// g.write('/*OPTIONAL*/')
		}
		g.expr_with_cast(it.types[0], g.fn_decl.return_type, it.exprs[0])
	}
	g.writeln(';')
}

fn (g mut Gen) const_decl(node ast.ConstDecl) {
	for i, field in node.fields {
		name := field.name.replace('.', '__')
		expr := node.exprs[i]
		match expr {
			// Simple expressions should use a #define
			// so that we don't pollute the binary with unnecessary global vars
			// Do not do this when building a module, otherwise the consts
			// will not be accessible.
			ast.CharLiteral, ast.IntegerLiteral {
				g.definitions.write('#define $name ')
				// TODO hack. Cut the generated value and paste it into definitions.
				g.write('//')
				pos := g.out.len
				g.expr(expr)
				mut b := g.out.buf[pos..g.out.buf.len].clone()
				b << `\0`
				val := string(b)
				// val += '\0'
				// g.out.go_back(val.len)
				// println('pos=$pos buf.len=$g.out.buf.len len=$g.out.len val.len=$val.len val="$val"\n')
				g.writeln('')
				g.definitions.writeln(val)
			}
			else {
				styp := g.typ(field.typ)
				g.definitions.writeln('$styp $name; // inited later') // = ')
				// TODO
				// g.expr(node.exprs[i])
			}
	}
	}
}

fn (g mut Gen) call_args(args []ast.CallArg) {
	for i, arg in args {
		if table.type_is_variadic(arg.expected_type) {
			struct_name := 'varg_' + g.typ(arg.expected_type).replace('*', '_ptr')
			len := args.len - i
			type_str := int(arg.expected_type).str()
			if len > g.varaidic_args[type_str] {
				g.varaidic_args[type_str] = len
			}
			g.write('($struct_name){.len=$len,.args={')
			for j in i .. args.len {
				g.ref_or_deref_arg(args[j])
				g.expr(args[j].expr)
				if j < args.len - 1 {
					g.write(', ')
				}
			}
			g.write('}}')
			break
		}
		if arg.expected_type != 0 {
			g.ref_or_deref_arg(arg)
		}
		g.expr(arg.expr)
		if i != args.len - 1 {
			g.write(', ')
		}
	}
}

[inline]
fn (g mut Gen) ref_or_deref_arg(arg ast.CallArg) {
	arg_is_ptr := table.type_is_ptr(arg.expected_type) || arg.expected_type == table.voidptr_type_idx
	expr_is_ptr := table.type_is_ptr(arg.typ)
	if arg.is_mut && !arg_is_ptr {
		g.write('&/*mut*/')
	}
	else if arg_is_ptr && !expr_is_ptr {
		g.write('&/*q*/')
	}
	else if !arg_is_ptr && expr_is_ptr {
		// Dereference a pointer if a value is required
		g.write('*/*d*/')
	}
}

fn verror(s string) {
	println('cgen error: $s')
	// exit(1)
}

const (
// TODO all builtin types must be lowercase
	builtins = ['string', 'array', 'KeyValue', 'DenseArray', 'map', 'Option']
)

fn (g mut Gen) write_builtin_types() {
	mut builtin_types := []table.TypeSymbol // builtin types
	// builtin types need to be on top
	// everything except builtin will get sorted
	for builtin_name in builtins {
		builtin_types << g.table.types[g.table.type_idxs[builtin_name]]
	}
	g.write_types(builtin_types)
}

// C struct definitions, ordered
// Sort the types, make sure types that are referenced by other types
// are added before them.
fn (g mut Gen) write_sorted_types() {
	mut types := []table.TypeSymbol // structs that need to be sorted
	for typ in g.table.types {
		if !(typ.name in builtins) {
			types << typ
		}
	}
	// sort structs
	types_sorted := g.sort_structs(types)
	// Generate C code
	g.definitions.writeln('// builtin types:')
	// g.write_types(builtin_types)
	g.definitions.writeln('//------------------ #endbuiltin')
	g.write_types(types_sorted)
}

fn (g mut Gen) write_types(types []table.TypeSymbol) {
	for i, typ in types {
		if typ.name.starts_with('C.') {
			continue
		}
		// sym := g.table.get_type_symbol(typ)
		name := typ.name.replace('.', '__')
		match typ.info {
			table.Struct {
				info := typ.info as table.Struct
				// g.definitions.writeln('typedef struct {')
				g.definitions.writeln('struct $name {')
				for field in info.fields {
					type_name := g.typ(field.typ)
					g.definitions.writeln('\t$type_name $field.name;')
				}
				// g.definitions.writeln('} $name;\n')
				//
				g.definitions.writeln('};\n')
				g.typedefs.writeln('#define _type_idx_$name $i')
			}
			table.Enum {
				g.definitions.writeln('typedef enum {')
				for j, val in it.vals {
					g.definitions.writeln('\t${name}_$val, // $j')
				}
				g.definitions.writeln('} $name;\n')
			}
			table.SumType {
				g.definitions.writeln('// Sum type')
				g.definitions.writeln('
				typedef struct {
void* obj;
int typ;
} $name;')
			}
			else {}
	}
	}
}

// sort structs by dependant fields
fn (g &Gen) sort_structs(types []table.TypeSymbol) []table.TypeSymbol {
	mut dep_graph := depgraph.new_dep_graph()
	// types name list
	mut type_names := []string
	for typ in types {
		type_names << typ.name
	}
	// loop over types
	for t in types {
		// create list of deps
		mut field_deps := []string
		match t.info {
			table.Struct {
				info := t.info as table.Struct
				for field in info.fields {
					// Need to handle fixed size arrays as well (`[10]Point`)
					// ft := if field.typ.starts_with('[') { field.typ.all_after(']') } else { field.typ }
					dep := g.table.get_type_symbol(field.typ).name
					// skip if not in types list or already in deps
					if !(dep in type_names) || dep in field_deps || table.type_is_ptr(field.typ) {
						continue
					}
					field_deps << dep
				}
			}
			else {}
	}
		// add type and dependant types to graph
		dep_graph.add(t.name, field_deps)
	}
	// sort graph
	dep_graph_sorted := dep_graph.resolve()
	if !dep_graph_sorted.acyclic {
		verror('cgen.sort_structs(): the following structs form a dependency cycle:\n' + dep_graph_sorted.display_cycles() + '\nyou can solve this by making one or both of the dependant struct fields references, eg: field &MyStruct' + '\nif you feel this is an error, please create a new issue here: https://github.com/vlang/v/issues and tag @joe-conigliaro')
	}
	// sort types
	mut types_sorted := []table.TypeSymbol
	for node in dep_graph_sorted.nodes {
		types_sorted << g.table.types[g.table.type_idxs[node.name]]
	}
	return types_sorted
}

fn op_to_fn_name(name string) string {
	return match name {
		'+'{
			'_op_plus'
		}
		'-'{
			'_op_minus'
		}
		'*'{
			'_op_mul'
		}
		'/'{
			'_op_div'
		}
		'%'{
			'_op_mod'
		}
		else {
			'bad op $name'}
	}
}
