## build-trixie
### Create a Debian trixie minimal live system similar to 'DebianDog'

See more info about usage and changes/fixes at https://forum.puppylinux.com/viewtopic.php?p=159033#p159033    

#### Testing and profiling

`docs/testing.md` describes the three test layers (unit tests for the initrd
scripts, image tests on the built squashfs, boot tests under QEMU by BIOS,
UEFI and Secure Boot) and `docs/boot-profiling.md` the boot profiler and what
it found. `tools/build-unattended` runs the build without a keyboard.
`docs/plan-executable-checks.md` is the plan for checking that every program on
the image can run, now implemented: `tests/image/test_executables.sh` and
`tests/linuxrc/test_initrd_applets.sh` read the built image and initrd, and
`boot-test-programs.sh` and `boot-test-gui.sh` start the programs in a guest.
`docs/config-checks.md` is where every config stands after going through all of
them, and `tools/check-configs` is how that table was made.

#### Update 2025-11-29:    
Added "extra-commands" script, will run inside chroot, based on the idea of @IdfbAn          

#### Update: Now support for "xlibre" install (replacement of xorg). NOTE: only for amd64      
Run with .conf file *-xlibre.conf, e.g `./build-trixie configs-trixie/lxqt-full-xlibre.conf`      

This works very similar as the 'mklive-trixie' script:    
https://forum.puppylinux.com/viewtopic.php?p=122016#p122016     
except that it's very much simplified.


`fredx181, 2025-10-27, stripped down version of mklive-trixie`    
`supports only .conf files as an argument, e.g. ./build-trixie /path/to/myconfig.conf`    
`no dependency on yad (as this has no GUI), no dependency on files to download from the 'MakeLive' repository.`    


`Usage: ./build-trixie <config_file> (presets are in configs-trixie) `   
 `-help show this help `   
 `Example using one of the preset config files:`    
 `./build-trixie configs-trixie/lxqt-full.conf`    
 `Example using one of the preset config files to install xlibre rather than xorg:`       
 `./build-trixie configs-trixie/lxqt-full-xlibre.conf`       
 `Example with custom config file:`        
 `./build-trixie /path/to/my.conf `   

 
