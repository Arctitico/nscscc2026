set project_name thinpad_top
set project_path ./project
set project_part xc7a200tfbg676-2

file delete -force $project_path
create_project -force $project_name $project_path -part $project_part

set rtl_files [list \
    ../src/cpu_pkg.sv ../src/tools.sv ../src/alu.sv ../src/mul.sv \
    ../src/decoder.sv ../src/regfile.sv ../src/bpu.sv ../src/icache.sv \
    ../src/write_buffer.sv ../src/dcache.sv \
    ../src/IF.sv ../src/ID.sv ../src/DP.sv ../src/IS.sv ../src/RF.sv \
    ../src/EX1.sv ../src/EX2.sv ../src/CM.sv ../src/mycpu_top.sv \
    ../soc/sram_ctrl.sv ../soc/uart_phy.sv ../soc/uart_mm.sv \
    ../soc/mem_bridge.sv ../soc/board_clock.sv ../soc/thinpad_top.sv]
add_files -scan_for_includes $rtl_files
add_files -fileset constrs_1 ./constraints/soc.xdc

set_property top thinpad_top [current_fileset]
update_compile_order -fileset sources_1

puts "PROJECT: [file normalize $project_path/$project_name.xpr]"
close_project
