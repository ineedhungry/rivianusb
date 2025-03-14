#!/bin/bash -eu

function log_progress () {
  if declare -F setup_progress > /dev/null
  then
    setup_progress "create-backingfiles: $1"
    return
  fi
  echo "create-backingfiles: $1"
}

log_progress "starting"

CAM_SIZE="$1"
MUSIC_SIZE="$2"
LIGHTSHOW_SIZE="$3"
BOOMBOX_SIZE="$4"
# strip trailing slash that shell autocomplete might have added
BACKINGFILES_MOUNTPOINT="${5/%\//}"
USE_EXFAT="$6"

log_progress "cam: $CAM_SIZE, music: $MUSIC_SIZE, lightshow: $LIGHTSHOW_SIZE, boombox: $BOOMBOX_SIZE mountpoint: $BACKINGFILES_MOUNTPOINT, exfat: $USE_EXFAT"

function first_partition_offset () {
  local filename="$1"
  local size_in_bytes
  local size_in_sectors
  local sector_size
  local partition_start_sector

  size_in_bytes=$(sfdisk -l -o Size -q --bytes "$1" | tail -1)
  size_in_sectors=$(sfdisk -l -o Sectors -q "$1" | tail -1)
  sector_size=$(( size_in_bytes / size_in_sectors ))
  partition_start_sector=$(sfdisk -l -o Start -q "$1" | tail -1)

  echo $(( partition_start_sector * sector_size ))
}

# Note that this uses powers-of-two rather than the powers-of-ten that are
# generally used to market storage.
function dehumanize () {
  echo $(($(echo "$1" | sed 's/GB/G/;s/MB/M/;s/KB/K/;s/G/*1024M/;s/M/*1024K/;s/K/*1024/')))
}

function is_percent() {
  echo "$1" | grep '%' > /dev/null
}

function available_space () {
  freespace=$(df --output=size --block-size=1K "$BACKINGFILES_MOUNTPOINT/" | tail -n 1)
  # reserve 10 GB for filesystem bookkeeping and snapshotting
  # (in kilobytes so 10M KB)
  padding=$(dehumanize "10M")
  echo $((freespace-padding))
}

function calc_size () {
  local requestedsize="${!1}"
  if is_percent "$requestedsize"
  then
    case ${1} in
      CAM_SIZE)
        requestedsize=30G
        ;;
      MUSIC_SIZE)
        requestedsize=4G
        ;;
      BOOMBOX_SIZE)
        requestedsize=100M
        ;;
      LIGHTSHOW_SIZE)
        requestedsize=1G
        ;;
      *)
        log_progress "Percentage-based size no longer supported, use fixed size instead." > /dev/stderr
        exit 1
        ;;
    esac
    log_progress "Percentage-based size no longer supported, using default size of $requestedsize for $1" > /dev/stderr
  fi
  requestedsize="$(( $(dehumanize $requestedsize) / 1024 ))"
  echo "$requestedsize"
}

function add_drive () {
  local name="$1"
  local label="$2"
  local size="$3"
  local filename="$4"
  local useexfat="$5"
  local mountpoint=/mnt/"$name"

  if image_matches_params "$filename" "$size" &> /dev/null
  then
    return
  fi

  if [ "$size" -eq "0" ]
  then
    rm -f "$filename" &> /dev/null
    rm -f "$filename.opts" &> /dev/null
    rmdir "$mountpoint" &> /dev/null || true
    return
  fi

  log_progress "Allocating ${size}K for $filename..."
  truncate --size="$size"K "$filename"
  if [ "$useexfat" = true  ]
  then
    echo "type=7" | sfdisk "$filename" > /dev/null
  else
    echo "type=c" | sfdisk "$filename" > /dev/null
  fi

  local partition_offset
  partition_offset=$(first_partition_offset "$filename")

  loopdev=$(losetup_find_show -o "$partition_offset" "$filename")
  log_progress "Creating filesystem with label '$label'"
  if [ "$useexfat" = true  ]
  then
    mkfs.exfat "$loopdev" -L "$label"
  else
    mkfs.vfat "$loopdev" -F 32 -n "$label"
  fi
  losetup -d "$loopdev"


  if [ ! -e "$mountpoint" ]
  then
    mkdir "$mountpoint"
  fi
}

function check_for_exfat_support () {
  # First check for built-in ExFAT support
  # If that fails, check for an ExFAT module
  # in this last case exfat doesn't appear
  # in /proc/filesystems if the module is not loaded.
  if grep -q exfat /proc/filesystems &> /dev/null
  then
    return 0;
  elif modprobe -n exfat &> /dev/null
  then
    return 0;
  else 
    return 1;  
  fi
}

function closeenough () {
  DIFF=$(($1-$2))
  if [ $DIFF -ge 0 ] && [ $DIFF -lt 10240 ]
  then
    true
    return
  elif [ $DIFF -lt 0 ] && [ $DIFF -gt -10240 ]
  then
    true
    return
  fi
  false
}

function image_size_kb () {
  echo $(($(stat --printf="%s" "$1")/1024))
}

function release_all_images () {
  systemctl stop teslausb || true
  killall archiveloop || true
  /root/bin/disable_gadget.sh || true
  umount -d /mnt/cam || true
  umount -d /mnt/music || true
  umount -d /mnt/lightshow || true
  umount -d /mnt/boombox || true
  umount -d /backingfiles/snapshots/snap*/mnt || true
}

function image_matches_params () {
  local image_file="$1"
  local requested_image_size="$2"

  if [ "$requested_image_size" -gt 0 ]
  then
    if [ -e "$image_file" ]
    then
      local current_image_size=$(image_size_kb "$image_file")
      if ! closeenough "$requested_image_size" "$current_image_size"
      then
        log_progress "$image_file should be resized (to $requested_image_size from $current_image_size)"
        return 1
      fi
      # TODO check if filesystem matches
    else
      log_progress "$image_file should be created"
      return 1
    fi
  else
    if [ -e "$image_file" ]
    then
      log_progress "$image_file should be deleted"
      return 1
    fi
  fi
  return 0
}

# Check if kernel supports ExFAT 
if ! check_for_exfat_support
then
  if [ "$USE_EXFAT" = true ]
  then
    log_progress "kernel does not support ExFAT FS. Reverting to FAT32."
    USE_EXFAT=false
  fi
else
  # install exfatprogs if needed
  if ! hash mkfs.exfat &> /dev/null
  then
    /root/bin/remountfs_rw
    if ! apt install -y exfatprogs
    then
      log_progress "kernel supports ExFAT, but exfatprogs package does not exist."
      if [ "$USE_EXFAT" = true ]
      then
        log_progress "Reverting to FAT32"
        USE_EXFAT=false
      fi
    fi
  fi
fi

# some distros don't include mkfs.vfat
if ! hash mkfs.vfat
then
  apt-get -y --force-yes install dosfstools
fi

CAM_DISK_FILE_NAME="$BACKINGFILES_MOUNTPOINT/cam_disk.bin"
MUSIC_DISK_FILE_NAME="$BACKINGFILES_MOUNTPOINT/music_disk.bin"
LIGHTSHOW_DISK_FILE_NAME="$BACKINGFILES_MOUNTPOINT/lightshow_disk.bin"
BOOMBOX_DISK_FILE_NAME="$BACKINGFILES_MOUNTPOINT/boombox_disk.bin"

CAM_DISK_SIZE="$(calc_size CAM_SIZE)"
MUSIC_DISK_SIZE="$(calc_size MUSIC_SIZE)"
LIGHTSHOW_DISK_SIZE="$(calc_size LIGHTSHOW_SIZE)"
BOOMBOX_DISK_SIZE="$(calc_size BOOMBOX_SIZE)"

if image_matches_params "$CAM_DISK_FILE_NAME" "$CAM_DISK_SIZE" && \
   image_matches_params "$MUSIC_DISK_FILE_NAME" "$MUSIC_DISK_SIZE" && \
   image_matches_params "$LIGHTSHOW_DISK_FILE_NAME" "$LIGHTSHOW_DISK_SIZE" && \
   image_matches_params "$BOOMBOX_DISK_FILE_NAME" "$BOOMBOX_DISK_SIZE"
then
  log_progress "No need to update disk images"
  exit 0
fi

# reduce the value of the given variable by 5%, but only until the specified minimum is reached
function reduce_size () {
  local curval="${!1}"
  local minval=$(( $(dehumanize "$2") / 1024))
  if [ "$curval" -le "$minval" ]
  then
    return
  fi
  local newval=$((curval*95/100))
  if [ "$newval" -ge "$minval" ]
  then
    export $1=$newval
  else
    export $1=$minval
  fi
  adjusted=true
}

if [ "$((CAM_DISK_SIZE+MUSIC_DISK_SIZE+LIGHTSHOW_DISK_SIZE+BOOMBOX_DISK_SIZE))" -gt "$(available_space)" ]
then
  log_progress "Total requested size exceeds available space"
  
  while [ "$((CAM_DISK_SIZE+MUSIC_DISK_SIZE+LIGHTSHOW_DISK_SIZE+BOOMBOX_DISK_SIZE))" -gt "$(available_space)" ]
  do
    adjusted=false
    reduce_size CAM_DISK_SIZE "30G"
    reduce_size MUSIC_DISK_SIZE "4G"
    reduce_size LIGHTSHOW_DISK_SIZE "1G"
    reduce_size BOOMBOX_DISK_SIZE "500M"
    if [ "$adjusted" = "false" ]
    then
      log_progress "Failed to adjust sizes to fit available space"
      exit 1
    fi
  done
  log_progress "Adjusted sizes to ${CAM_DISK_SIZE}K / ${MUSIC_DISK_SIZE}K / ${LIGHTSHOW_DISK_SIZE}K / ${BOOMBOX_DISK_SIZE}K"
fi

# if we get here, one or more of the images need to be created, deleted or updated, and there should be
# enough space to do so, possibly requiring deleting some or all of the snapshots to free up space first.

# TODO: resize images where possible, instead of recreating them
if [ -e "$CAM_DISK_FILE_NAME" ] || [ -e "$MUSIC_DISK_FILE_NAME" ] || [ -e "$LIGHTSHOW_DISK_FILE_NAME" ] || [ -e "$BOOMBOX_DISK_FILE_NAME" ] || [ -e "$BACKINGFILES_MOUNTPOINT/snapshots" ]
then
  if [ -t 0 ]
  then
    read -r -p 'Delete and recreate drives? (yes/cancel)' answer
    case ${answer:0:1} in
      y|Y )
      ;;
      * )
        log_progress "aborting"
        exit 1
      ;;
    esac
  fi
fi

# shut down everything that might be using any of the drive images
release_all_images

add_drive "cam" "CAM" "$CAM_DISK_SIZE" "$CAM_DISK_FILE_NAME" "$USE_EXFAT"
if [ "$CAM_DISK_SIZE" -eq 0 ]
then
  rm -rf "$BACKINGFILES_MOUNTPOINT/snapshots" &> /dev/null
fi

add_drive "music" "MUSIC" "$MUSIC_DISK_SIZE" "$MUSIC_DISK_FILE_NAME" "$USE_EXFAT"

add_drive "lightshow" "LIGHTSHOW" "$LIGHTSHOW_DISK_SIZE" "$LIGHTSHOW_DISK_FILE_NAME" "$USE_EXFAT"

add_drive "boombox" "BOOMBOX" "$BOOMBOX_DISK_SIZE" "$BOOMBOX_DISK_FILE_NAME" "$USE_EXFAT"

log_progress "done"
