import 'dart:convert';
import 'dart:io';

import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;
import 'package:tool/src/book.dart';

import 'package:tool/src/term.dart' as term;

/// Runs the tests.

// REGEX Patterns
final _expectedOutputPattern = RegExp(r"// expect: ?(.*)");
final _expectedErrorPattern = RegExp(r"// (Error.*)");
final _errorLinePattern = RegExp(r"// \[((java|c) )?line (\d+)\] (Error.*)");
final _expectedRuntimeErrorPattern = RegExp(r"// expect runtime error: (.+)");
final _syntaxErrorPattern = RegExp(r"\[.*line (\d+)\] (Error.+)");
final _stackTracePattern = RegExp(r"\[line (\d+)\]");
final _nonTestPattern = RegExp(r"// nontest");

class Interpreter {
  final String name;
  final String language;
  final String executable;
  final List<String> args;
  final Map<String, String> tests;

  Interpreter(this.name, this.language, this.executable, this.args, this.tests);
}

class ExpectedOutput {
  final int line;
  final String output;

  ExpectedOutput(this.line, this.output);
}

class Stats {
  int passed;
  int failed;
  int skipped;
  int expectations;

  Stats(this.passed, this.failed, this.skipped, this.expectations);
}

class Suites {
  final allSuites = <String, Interpreter>{};
  final cSuites = <String>[];
  final javaSuites = <String>[];
  final userJavaSuites = <String>[];
  final userCSuites = <String>[];
}

void main(List<String> arguments) {
  if (arguments.length == 0 || arguments[0] == "-h") {
    usage();
    exit(1);
  }

  String filterPath; // removed global
  Interpreter interpreter;

  Suites suites = _defineTestSuites();

  // using built in binaries
  if (arguments[0] == "-b") {
    // using built-in c interp
    if (arguments[1] == "clox") {
      if (arguments.length > 2) {
        filterPath = arguments[2];
      }
      _runSuites(suites.cSuites, filterPath);

      // using built-in java binary
    } else if (arguments[1] == "jlox") {
      if (arguments.length > 2) {
        filterPath = arguments[2];
      }
      _runSuites(suites.javaSuites, filterPath);
    }

    // using user supplied binary
  } else if (arguments[0] == "-u") {
    if (arguments[1] == "c") {
      // parse interpeter path

      if (arguments.length > 3) {
        filterPath = arguments[3];
      }
      _runSuites(suites.userCSuites, filterPath);

      // using user java
    } else if (arguments[1] == "java") {
      if (arguments.length > 3) {
        filterPath = arguments[3];
      }
      _runSuites(suites.userJavaSuites, filterPath);
    }
  } else {
    print("You must select either -b or -u");
    exit(1);
  }
}

void _runSuites(List<String> names, String filterPath) {
  // Iterate over a list of test suitess
  //
  // Args:
  //    names: language names?
  //    filterPath: test filters
  //
  // Returns:  Void
  var anyFailed = false;
  for (var name in names) {
    print("=== $name ===");
    if (!_runSuite(name, filterPath)) anyFailed = true;
  }

  if (anyFailed) exit(1);
}

bool _runSuite(String name, String filterPath) {
  // Args:
  //  name:
  //  filterPath: test filters
  _interpreter = _allSuites[name]; // assignment...

  Stats stats = new Stats(0, 0, 0, 0);

  // grab every test in test.lox
  for (var file in Glob("test/**.lox").listSync()) {
    _runTest(file.path, filterPath, stats);
  }

  term.clearLine();

  // if (stats.failed == 0) {
  //   print("All ${term.green(Stats.passed)} tests passed "
  //       "($_expectations expectations).");
  // } else {
  //   print("${term.green(_passed)} tests passed. "
  //       "${term.red(_failed)} tests failed.");
  // }

  return stats.failed == 0;
}

void _runTest(String path, String filterPath, Stats stats) {
  // Args:
  //   Path:
  //   filterPath:

  if (path.contains("benchmark")) return;

  // Make a nice short path relative to the working directory. Normalize it to
  // use "/" since the interpreters expect the argument to use that.
  path = p.posix.normalize(path);

  // Check if we are just running a subset of the tests.
  if (filterPath != null) {
    var thisTest = p.posix.relative(path, from: "test");
    if (!thisTest.startsWith(filterPath)) return;
  }

  // Update the status line.
  var grayPath = term.gray("($path)");
  term.writeLine("Passed: ${term.green(_passed)} "
      "Failed: ${term.red(_failed)} "
      "Skipped: ${term.yellow(_skipped)} $grayPath");

  // Read the test and parse out the expectations.
  var test = Test(path);

  // See if it's a skipped or non-test file.
  if (!test.parse()) return;

  var failures = test.run();

  // Display the results.
  if (failures.isEmpty) {
    _passed++;
  } else {
    _failed++;
    term.writeLine("${term.red("FAIL")} $path");
    print("");
    for (var failure in failures) {
      print("     ${term.pink(failure)}");
    }
    print("");
  }
}

// // class Test {
//   final String _path;

//   final _expectedOutput = <ExpectedOutput>[];

//   /// The set of expected compile error messages.
//   final _expectedErrors = <String>{};

//   /// The expected runtime error message or `null` if there should not be one.
//   String _expectedRuntimeError;

//   /// If there is an expected runtime error, the line it should occur on.
//   int _runtimeErrorLine = 0;

//   int _expectedExitCode = 0;

//   /// The list of failure message lines.
//   final _failures = <String>[];

//   Test(this._path);

//   bool parse() {
//     // Get the path components.
//     var parts = _path.split("/");
//     var subpath = "";
//     String state;

//     // Figure out the state of the test. We don't break out of this loop because
//     // we want lines for more specific paths to override more general ones.
//     for (var part in parts) {
//       if (subpath.isNotEmpty) subpath += "/";
//       subpath += part;

//       if (_interpreter.tests.containsKey(subpath)) {
//         state = _interpreter.tests[subpath];
//       }
//     }

//     if (state == null) {
//       throw "Unknown test state for '$_path'.";
//     } else if (state == "skip") {
//       _skipped++;
//       return false;
//     }

//     var lines = File(_path).readAsLinesSync();
//     for (var lineNum = 1; lineNum <= lines.length; lineNum++) {
//       var line = lines[lineNum - 1];

//       // Not a test file at all, so ignore it.
//       var match = _nonTestPattern.firstMatch(line);
//       if (match != null) return false;

//       match = _expectedOutputPattern.firstMatch(line);
//       if (match != null) {
//         _expectedOutput.add(ExpectedOutput(lineNum, match[1]));
//         _expectations++;
//         continue;
//       }

//       match = _expectedErrorPattern.firstMatch(line);
//       if (match != null) {
//         _expectedErrors.add("[$lineNum] ${match[1]}");

//         // If we expect a compile error, it should exit with EX_DATAERR.
//         _expectedExitCode = 65;
//         _expectations++;
//         continue;
//       }

//       match = _errorLinePattern.firstMatch(line);
//       if (match != null) {
//         // The two interpreters are slightly different in terms of which
//         // cascaded errors may appear after an initial compile error because
//         // their panic mode recovery is a little different. To handle that,
//         // the tests can indicate if an error line should only appear for a
//         // certain interpreter.
//         var language = match[2];
//         if (language == null || language == _interpreter.language) {
//           _expectedErrors.add("[${match[3]}] ${match[4]}");

//           // If we expect a compile error, it should exit with EX_DATAERR.
//           _expectedExitCode = 65;
//           _expectations++;
//         }
//         continue;
//       }

//       match = _expectedRuntimeErrorPattern.firstMatch(line);
//       if (match != null) {
//         _runtimeErrorLine = lineNum;
//         _expectedRuntimeError = match[1];
//         // If we expect a runtime error, it should exit with EX_SOFTWARE.
//         _expectedExitCode = 70;
//         _expectations++;
//       }
//     }

//     if (_expectedErrors.isNotEmpty && _expectedRuntimeError != null) {
//       print("${term.magenta('TEST ERROR')} $_path");
//       print("     Cannot expect both compile and runtime errors.");
//       print("");
//       return false;
//     }

//     // If we got here, it's a valid test.
//     return true;
//   }

//   /// Invoke the interpreter and run the test.
//   List<String> run() {
//     var args = [..._interpreter.args, _path];
//     var result = Process.runSync(_interpreter.executable, args);

//     // Normalize Windows line endings.
//     var outputLines = const LineSplitter().convert(result.stdout as String);
//     var errorLines = const LineSplitter().convert(result.stderr as String);

//     // Validate that an expected runtime error occurred.
//     if (_expectedRuntimeError != null) {
//       _validateRuntimeError(errorLines);
//     } else {
//       _validateCompileErrors(errorLines);
//     }

//     _validateExitCode(result.exitCode, errorLines);
//     _validateOutput(outputLines);
//     return _failures;
//   }

//   void _validateRuntimeError(List<String> errorLines) {
//     if (errorLines.length < 2) {
//       fail("Expected runtime error '$_expectedRuntimeError' and got none.");
//       return;
//     }

//     if (errorLines[0] != _expectedRuntimeError) {
//       fail("Expected runtime error '$_expectedRuntimeError' and got:");
//       fail(errorLines[0]);
//     }

//     // Make sure the stack trace has the right line.
//     RegExpMatch match;
//     var stackLines = errorLines.sublist(1);
//     for (var line in stackLines) {
//       match = _stackTracePattern.firstMatch(line);
//       if (match != null) break;
//     }

//     if (match == null) {
//       fail("Expected stack trace and got:", stackLines);
//     } else {
//       var stackLine = int.parse(match[1]);
//       if (stackLine != _runtimeErrorLine) {
//         fail("Expected runtime error on line $_runtimeErrorLine "
//             "but was on line $stackLine.");
//       }
//     }
//   }

//   void _validateCompileErrors(List<String> error_lines) {
//     // Validate that every compile error was expected.
//     var foundErrors = <String>{};
//     var unexpectedCount = 0;
//     for (var line in error_lines) {
//       var match = _syntaxErrorPattern.firstMatch(line);
//       if (match != null) {
//         var error = "[${match[1]}] ${match[2]}";
//         if (_expectedErrors.contains(error)) {
//           foundErrors.add(error);
//         } else {
//           if (unexpectedCount < 10) {
//             fail("Unexpected error:");
//             fail(line);
//           }
//           unexpectedCount++;
//         }
//       } else if (line != "") {
//         if (unexpectedCount < 10) {
//           fail("Unexpected output on stderr:");
//           fail(line);
//         }
//         unexpectedCount++;
//       }
//     }

//     if (unexpectedCount > 10) {
//       fail("(truncated ${unexpectedCount - 10} more...)");
//     }

//     // Validate that every expected error occurred.
//     for (var error in _expectedErrors.difference(foundErrors)) {
//       fail("Missing expected error: $error");
//     }
//   }

//   void _validateExitCode(int exitCode, List<String> errorLines) {
//     if (exitCode == _expectedExitCode) return;

//     if (errorLines.length > 10) {
//       errorLines = errorLines.sublist(0, 10);
//       errorLines.add("(truncated...)");
//     }

//     fail("Expected return code $_expectedExitCode and got $exitCode. Stderr:",
//         errorLines);
//   }

//   void _validateOutput(List<String> outputLines) {
//     // Remove the trailing last empty line.
//     if (outputLines.isNotEmpty && outputLines.last == "") {
//       outputLines.removeLast();
//     }

//     var index = 0;
//     for (; index < outputLines.length; index++) {
//       var line = outputLines[index];
//       if (index >= _expectedOutput.length) {
//         fail("Got output '$line' when none was expected.");
//         continue;
//       }

//       var expected = _expectedOutput[index];
//       if (expected.output != line) {
//         fail("Expected output '${expected.output}' on line ${expected.line} "
//             " and got '$line'.");
//       }
//     }

//     while (index < _expectedOutput.length) {
//       var expected = _expectedOutput[index];
//       fail("Missing expected output '${expected.output}' on line "
//           "${expected.line}.");
//       index++;
//     }
//   }

//   void fail(String message, [List<String> lines]) {
//     _failures.add(message);
//     if (lines != null) _failures.addAll(lines);
//   }
// }

Suites _defineTestSuites() {
  Suites suites = new Suites();

  void c(String name, Map<String, String> tests) {
    var executable = name == "clox" ? "build/cloxd" : "build/$name";
    suites.allSuites[name] = Interpreter(name, "c", executable, [], tests);
    suites.cSuites.add(name);
  }

  void java(String name, Map<String, String> tests) {
    var dir = name == "jlox" ? "build/java" : "build/gen/$name";
    suites.allSuites[name] = Interpreter(name, "java", "java",
        ["-cp", dir, "com.craftinginterpreters.lox.Lox"], tests);
    suites.javaSuites.add(name);
  }

  void user(String name, Map<String, String> tests) {}

  // These are just for earlier chapters.
  var earlyChapters = {
    "test/scanning": "skip",
    "test/expressions": "skip",
  };

  // JVM doesn't correctly implement IEEE equality on boxed doubles.
  var javaNaNEquality = {
    "test/number/nan_equality.lox": "skip",
  };

  // No hardcoded limits in jlox.
  var noJavaLimits = {
    "test/limit/loop_too_large.lox": "skip",
    "test/limit/no_reuse_constants.lox": "skip",
    "test/limit/too_many_constants.lox": "skip",
    "test/limit/too_many_locals.lox": "skip",
    "test/limit/too_many_upvalues.lox": "skip",

    // Rely on JVM for stack overflow checking.
    "test/limit/stack_overflow.lox": "skip",
  };

  // No classes in Java yet.
  var noJavaClasses = {
    "test/assignment/to_this.lox": "skip",
    "test/call/object.lox": "skip",
    "test/class": "skip",
    "test/closure/close_over_method_parameter.lox": "skip",
    "test/constructor": "skip",
    "test/field": "skip",
    "test/inheritance": "skip",
    "test/method": "skip",
    "test/number/decimal_point_at_eof.lox": "skip",
    "test/number/trailing_dot.lox": "skip",
    "test/operator/equals_class.lox": "skip",
    "test/operator/equals_method.lox": "skip",
    "test/operator/not_class.lox": "skip",
    "test/regression/394.lox": "skip",
    "test/super": "skip",
    "test/this": "skip",
    "test/return/in_method.lox": "skip",
    "test/variable/local_from_method.lox": "skip",
  };

  // No functions in Java yet.
  var noJavaFunctions = {
    "test/call": "skip",
    "test/closure": "skip",
    "test/for/closure_in_body.lox": "skip",
    "test/for/return_closure.lox": "skip",
    "test/for/return_inside.lox": "skip",
    "test/for/syntax.lox": "skip",
    "test/function": "skip",
    "test/operator/not.lox": "skip",
    "test/regression/40.lox": "skip",
    "test/return": "skip",
    "test/unexpected_character.lox": "skip",
    "test/while/closure_in_body.lox": "skip",
    "test/while/return_closure.lox": "skip",
    "test/while/return_inside.lox": "skip",
  };

  // No resolution in Java yet.
  var noJavaResolution = {
    "test/closure/assign_to_shadowed_later.lox": "skip",
    "test/function/local_mutual_recursion.lox": "skip",
    "test/variable/collide_with_parameter.lox": "skip",
    "test/variable/duplicate_local.lox": "skip",
    "test/variable/duplicate_parameter.lox": "skip",
    "test/variable/early_bound.lox": "skip",

    // Broken because we haven"t fixed it yet by detecting the error.
    "test/return/at_top_level.lox": "skip",
    "test/variable/use_local_in_initializer.lox": "skip",
  };

  // No control flow in C yet.
  var noCControlFlow = {
    "test/block/empty.lox": "skip",
    "test/for": "skip",
    "test/if": "skip",
    "test/limit/loop_too_large.lox": "skip",
    "test/logical_operator": "skip",
    "test/variable/unreached_undefined.lox": "skip",
    "test/while": "skip",
  };

  // No functions in C yet.
  var noCFunctions = {
    "test/call": "skip",
    "test/closure": "skip",
    "test/for/closure_in_body.lox": "skip",
    "test/for/return_closure.lox": "skip",
    "test/for/return_inside.lox": "skip",
    "test/for/syntax.lox": "skip",
    "test/function": "skip",
    "test/limit/no_reuse_constants.lox": "skip",
    "test/limit/stack_overflow.lox": "skip",
    "test/limit/too_many_constants.lox": "skip",
    "test/limit/too_many_locals.lox": "skip",
    "test/limit/too_many_upvalues.lox": "skip",
    "test/regression/40.lox": "skip",
    "test/return": "skip",
    "test/unexpected_character.lox": "skip",
    "test/variable/collide_with_parameter.lox": "skip",
    "test/variable/duplicate_parameter.lox": "skip",
    "test/variable/early_bound.lox": "skip",
    "test/while/closure_in_body.lox": "skip",
    "test/while/return_closure.lox": "skip",
    "test/while/return_inside.lox": "skip",
  };

  // No classes in C yet.
  var noCClasses = {
    "test/assignment/to_this.lox": "skip",
    "test/call/object.lox": "skip",
    "test/class": "skip",
    "test/closure/close_over_method_parameter.lox": "skip",
    "test/constructor": "skip",
    "test/field": "skip",
    "test/inheritance": "skip",
    "test/method": "skip",
    "test/number/decimal_point_at_eof.lox": "skip",
    "test/number/trailing_dot.lox": "skip",
    "test/operator/equals_class.lox": "skip",
    "test/operator/equals_method.lox": "skip",
    "test/operator/not.lox": "skip",
    "test/operator/not_class.lox": "skip",
    "test/regression/394.lox": "skip",
    "test/return/in_method.lox": "skip",
    "test/super": "skip",
    "test/this": "skip",
    "test/variable/local_from_method.lox": "skip",
  };

  // No inheritance in C yet.
  var noCInheritance = {
    "test/class/local_inherit_other.lox": "skip",
    "test/class/local_inherit_self.lox": "skip",
    "test/class/inherit_self.lox": "skip",
    "test/class/inherited_method.lox": "skip",
    "test/inheritance": "skip",
    "test/regression/394.lox": "skip",
    "test/super": "skip",
  };

  java("jlox", {
    "test": "pass",
    ...earlyChapters,
    ...javaNaNEquality,
    ...noJavaLimits,
  });

  java("chap04_scanning", {
    // No interpreter yet.
    "test": "skip",
    "test/scanning": "pass"
  });

  // No test for chapter 5. It just has a hardcoded main() in AstPrinter.

  java("chap06_parsing", {
    // No real interpreter yet.
    "test": "skip",
    "test/expressions/parse.lox": "pass"
  });

  java("chap07_evaluating", {
    // No real interpreter yet.
    "test": "skip",
    "test/expressions/evaluate.lox": "pass"
  });

  java("chap08_statements", {
    "test": "pass",
    ...earlyChapters,
    ...javaNaNEquality,
    ...noJavaLimits,
    ...noJavaFunctions,
    ...noJavaResolution,
    ...noJavaClasses,

    // No control flow.
    "test/block/empty.lox": "skip",
    "test/for": "skip",
    "test/if": "skip",
    "test/logical_operator": "skip",
    "test/while": "skip",
    "test/variable/unreached_undefined.lox": "skip",
  });

  java("chap09_control", {
    "test": "pass",
    ...earlyChapters,
    ...javaNaNEquality,
    ...noJavaLimits,
    ...noJavaFunctions,
    ...noJavaResolution,
    ...noJavaClasses,
  });

  java("chap10_functions", {
    "test": "pass",
    ...earlyChapters,
    ...javaNaNEquality,
    ...noJavaLimits,
    ...noJavaResolution,
    ...noJavaClasses,
  });

  java("chap11_resolving", {
    "test": "pass",
    ...earlyChapters,
    ...javaNaNEquality,
    ...noJavaLimits,
    ...noJavaClasses,
  });

  java("chap12_classes", {
    "test": "pass",
    ...earlyChapters,
    ...noJavaLimits,
    ...javaNaNEquality,

    // No inheritance.
    "test/class/local_inherit_other.lox": "skip",
    "test/class/local_inherit_self.lox": "skip",
    "test/class/inherit_self.lox": "skip",
    "test/class/inherited_method.lox": "skip",
    "test/inheritance": "skip",
    "test/regression/394.lox": "skip",
    "test/super": "skip",
  });

  java("chap13_inheritance", {
    "test": "pass",
    ...earlyChapters,
    ...javaNaNEquality,
    ...noJavaLimits,
  });

  c("clox", {
    "test": "pass",
    ...earlyChapters,
  });

  c("chap17_compiling", {
    // No real interpreter yet.
    "test": "skip",
    "test/expressions/evaluate.lox": "pass",
  });

  c("chap18_types", {
    // No real interpreter yet.
    "test": "skip",
    "test/expressions/evaluate.lox": "pass",
  });

  c("chap19_strings", {
    // No real interpreter yet.
    "test": "skip",
    "test/expressions/evaluate.lox": "pass",
  });

  c("chap20_hash", {
    // No real interpreter yet.
    "test": "skip",
    "test/expressions/evaluate.lox": "pass",
  });

  c("chap21_global", {
    "test": "pass",
    ...earlyChapters,
    ...noCControlFlow,
    ...noCFunctions,
    ...noCClasses,

    // No blocks.
    "test/assignment/local.lox": "skip",
    "test/variable/in_middle_of_block.lox": "skip",
    "test/variable/in_nested_block.lox": "skip",
    "test/variable/scope_reuse_in_different_blocks.lox": "skip",
    "test/variable/shadow_and_local.lox": "skip",
    "test/variable/undefined_local.lox": "skip",

    // No local variables.
    "test/block/scope.lox": "skip",
    "test/variable/duplicate_local.lox": "skip",
    "test/variable/shadow_global.lox": "skip",
    "test/variable/shadow_local.lox": "skip",
    "test/variable/use_local_in_initializer.lox": "skip",
  });

  c("chap22_local", {
    "test": "pass",
    ...earlyChapters,
    ...noCControlFlow,
    ...noCFunctions,
    ...noCClasses,
  });

  c("chap23_jumping", {
    "test": "pass",
    ...earlyChapters,
    ...noCFunctions,
    ...noCClasses,
  });

  c("chap24_calls", {
    "test": "pass",
    ...earlyChapters,
    ...noCClasses,

    // No closures.
    "test/closure": "skip",
    "test/for/closure_in_body.lox": "skip",
    "test/for/return_closure.lox": "skip",
    "test/function/local_recursion.lox": "skip",
    "test/limit/too_many_upvalues.lox": "skip",
    "test/regression/40.lox": "skip",
    "test/while/closure_in_body.lox": "skip",
    "test/while/return_closure.lox": "skip",
  });

  c("chap25_closures", {
    "test": "pass",
    ...earlyChapters,
    ...noCClasses,
  });

  c("chap26_garbage", {
    "test": "pass",
    ...earlyChapters,
    ...noCClasses,
  });

  c("chap27_classes", {
    "test": "pass",
    ...earlyChapters,
    ...noCInheritance,

    // No methods.
    "test/assignment/to_this.lox": "skip",
    "test/class/local_reference_self.lox": "skip",
    "test/class/reference_self.lox": "skip",
    "test/closure/close_over_method_parameter.lox": "skip",
    "test/constructor": "skip",
    "test/field/get_and_set_method.lox": "skip",
    "test/field/method.lox": "skip",
    "test/field/method_binds_this.lox": "skip",
    "test/method": "skip",
    "test/operator/equals_class.lox": "skip",
    "test/operator/equals_method.lox": "skip",
    "test/return/in_method.lox": "skip",
    "test/this": "skip",
    "test/variable/local_from_method.lox": "skip",
  });

  c("chap28_methods", {
    "test": "pass",
    ...earlyChapters,
    ...noCInheritance,
  });

  c("chap29_superclasses", {
    "test": "pass",
    ...earlyChapters,
  });

  c("chap30_optimization", {
    "test": "pass",
    ...earlyChapters,
  });

  return suites;
}

void usage() {
  print(
      "Usage: dart mwm_test.dart [-b book [interpreter] | -u user [interpreter_path]]  [filter] ");

  print("\tdart mwm_test.dart -b jlox");
  print("\tdart mwm_test.dart -b clox");
  print("\tdart mwm_test.dart -b jlox chap04_scanning");
  print("");

  print("\tdart mwm_test.dart -u java /home/bin/jlox");
  print("\tdart mwm_test.dart -u java /home/bin/jlox chap04_scanning");
  print("\tdart mwm_test.dart -u c /home/bin/clox");
}
