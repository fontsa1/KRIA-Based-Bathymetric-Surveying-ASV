# KR260 PMOD1 pins for the ASV motor outputs (pins from the iotengineer22 KR260 PWM tutorial).
# Port names must match the block design's external ports EXACTLY (case-sensitive):
#   PWM_0 <- axi_timer_1/pwm0, PWM_1 <- axi_timer_0/pwm0, gpio_rtl_tri_o[0] <- AXI GPIO output
set_property PACKAGE_PIN H12 [get_ports PWM_0]
set_property PACKAGE_PIN E10 [get_ports PWM_1]
set_property PACKAGE_PIN B10 [get_ports {gpio_rtl_tri_o[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports PWM_0]
set_property IOSTANDARD LVCMOS33 [get_ports PWM_1]
set_property IOSTANDARD LVCMOS33 [get_ports {gpio_rtl_tri_o[0]}]
