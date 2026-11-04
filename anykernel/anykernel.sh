### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers
## 适配：Redmi K30 Ultra (cezanne) / MT6889 / 4.14.186 + EROFS

### AnyKernel setup
properties() { '
kernel.string=cezanne 4.14.186 + EROFS (HyperOS4 bring-up)
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=cezanne
device.name2=
device.name3=
device.name4=
device.name5=
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties


### AnyKernel install
## boot files attributes
boot_attributes() {
set_perm_recursive 0 0 755 644 $RAMDISK/*;
set_perm_recursive 0 0 750 750 $RAMDISK/init* $RAMDISK/sbin;
} # end attributes

# boot shell variables
# 只写分区名，ak3-core.sh 会自动在
# /dev/block/{mapper,by-name,bootdevice/by-name} 下定位
BLOCK=boot;
IS_SLOT_DEVICE=0;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh;

# boot install
dump_boot;

write_boot;
## end boot install
