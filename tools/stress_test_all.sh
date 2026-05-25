#!/bin/bash

# | `:new_cm`    | New Computer Modern Math      | CM / serif         |
# | `:pagella`   | TeX Gyre Pagella Math         | Palatino           |
# | `:luciole`   | Luciole Math                  | Humanist sans      |
# | `:stix_two`  | STIX Two Math v2.0.2          | Times              |
# | `:fira_math` | Fira Math + Fira Sans v0.3.4  | Geometric sans     |
# | `:schola`    | TeX Gyre Schola Math          | Century Schoolbook |
# | `:termes`    | TeX Gyre Termes Math          | Times New Roman    |
# | `:bonum`     | TeX Gyre Bonum Math           | ITC Bookman        |

julia stress_test_sheet.jl :new_cm stress_test_output_new_cm.png
julia stress_test_sheet.jl :pagella stress_test_output_pagella.png
julia stress_test_sheet.jl :luciole stress_test_output_luciole.png
julia stress_test_sheet.jl :stix_two stress_test_output_stix_two.png
julia stress_test_sheet.jl :fira_math stress_test_output_fira_math.png
julia stress_test_sheet.jl :schola stress_test_output_schola.png
julia stress_test_sheet.jl :termes stress_test_output_termes.png
julia stress_test_sheet.jl :bonum stress_test_output_bonum.png
