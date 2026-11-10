-----------------------------------------------------------------
--------------- Export Package  --------------------------------
-----------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;  
use IEEE.numeric_std.all;     

package pexport is

   type tExportRegs is array(0 to 31) of unsigned(63 downto 0);

   type cpu_export_type is record
      regs           : tExportRegs;
      FPUregs        : tExportRegs;
      cop0regs       : tExportRegs;
      pc             : unsigned(63 downto 0);
      hi             : unsigned(63 downto 0);
      lo             : unsigned(63 downto 0);
      opcode         : unsigned(31 downto 0);
      csr            : unsigned(31 downto 0);
   end record;
   
   constant export_init : cpu_export_type := (
      (others => (others => '0')), 
      (others => (others => '0')), 
      (others => (others => '0')), 
      (others => '0'), 
      (others => '0'), 
      (others => '0'), 
      (others => '0'), 
      (others => '0')
   );   
  
end package;
