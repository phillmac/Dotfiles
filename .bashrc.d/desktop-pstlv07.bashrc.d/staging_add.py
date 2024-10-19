
import math
import os
import subprocess
import sys
import time

from datetime import datetime
from pathlib import Path

# from b2sdk.v2 import ScanPoliciesManager
# from b2sdk.v2 import parse_folder
# from b2sdk.v2 import Synchronizer
# from b2sdk.v2 import SyncReport

def copy_large_file(src, dst):
    '''
    Copy a large file showing progress.
    '''
    print('copying "{}" --> "{}"'.format(src, dst))
    if os.path.exists(src) is False:
        print('ERROR: file does not exist: "{}"'.format(src))
        sys.exit(1)
    if os.path.exists(dst) is True:
        os.remove(dst)
    if os.path.exists(dst) is True:
        print('ERROR: file exists, cannot overwrite it: "{}"'.format(dst))
        sys.exit(1)

    # Start the timer and get the size.
    start = time.time()
    size = os.stat(src).st_size
    print('{} bytes'.format(size))

    # Adjust the chunk size to the input size.
    divisor = 10000  # .1%
    #chunk_size = size / divisor
    chunk_size = math.ceil( size / divisor )  # suggested by 0xmessi to fix an error.
    while chunk_size == 0 and divisor > 0:
        divisor /= 10
        chunk_size = size / divisor
    print('chunk size is {}'.format(chunk_size))

    # Copy.
    try:
        with open(src, 'rb') as ifp:
            with open(dst, 'wb') as ofp:
                copied = 0  # bytes
                chunk = ifp.read(chunk_size)
                while chunk:
                    # Write and calculate how much has been written so far.
                    ofp.write(chunk)
                    copied += len(chunk)
                    per = 100. * float(copied) / float(size)

                    # Calculate the estimated time remaining.
                    elapsed = time.time() - start  # elapsed so far
                    avg_time_per_byte = elapsed / float(copied)
                    remaining = size - copied
                    est = remaining * avg_time_per_byte
                    est1 = size * avg_time_per_byte
                    eststr = 'rem={:>.1f}s, tot={:>.1f}s'.format(est, est1)

                    # Write out the status.
                    sys.stdout.write('\r\033[K{:>6.1f}%  {}  {} --> {} '.format(per, eststr, src, dst))
                    sys.stdout.flush()

                    # Read in the next chunk.
                    chunk = ifp.read(chunk_size)

    except IOError as obj:
        print('\nERROR: {}'.format(obj))
        sys.exit(1)

    sys.stdout.write('\r\033[K')  # clear to EOL
    elapsed = time.time() - start
    print('copied "{}" --> "{}" in {:>.1f}s"'.format(src, dst, elapsed))

empty_cid = subprocess.check_output(['ipfs', 'object', 'new', 'unixfs-dir'], shell=False).decode().strip()

# Get the current directory
current_dir = Path.cwd()
# List all subdirectories and sort them by
# creation date
subdirs_sorted = sorted( (d for d in
    current_dir.iterdir() if d.is_dir()),
    key=lambda x: x.stat().st_ctime
)
# Convert to list if needed
subdirs_list = list(subdirs_sorted)
# Print the sorted subdirectories
for subdir in subdirs_list:
  # print(subdir)
  subdir_contents = [i for i in subdir.iterdir()]
  if not any(subdir_contents):
    print('Empty dir ', subdir)
    subdir.rmdir()
  else:
    for sub_child_dir in (d for d in subdir_contents if d.is_dir()):
      base_cid = subprocess.check_output(['ipfs', 'add', '-Q', '-r', '--pin=false', '.'], shell=False, cwd=sub_child_dir).decode().strip()

      print(base_cid, sub_child_dir)

      for mfs_item in [sub_child_dir.name, subdir.name, 'Downloads', 'Laptop']:
        base_cid = subprocess.check_output(['ipfs', 'object', 'patch', 'add-link', '--', empty_cid, mfs_item, base_cid], shell=False).decode().strip()
        print(base_cid, mfs_item)

      out_file = Path('H:/', 'ipfs-export', base_cid + '.car')
      print(out_file)
      process = subprocess.Popen(['ipfs', 'dag', 'export', '-p', base_cid], stdout=out_file.open('+w'), stderr=subprocess.PIPE)
      for c in iter(lambda: process.stderr.read(1), b""):
        sys.stdout.buffer.write(c)

      copy_dest = Path('X:', 'data', 'ipfs-staging', base_cid + '.car')
      copy_large_file(out_file, copy_dest)
      copy_dest.rename(Path('X:', 'data', 'ipfs-export', base_cid + '.car'))
      out_file.unlink()

      # Create a list to hold the new parts
      new_parts = []

      # Iterate through the parts of the source directory
      for part in sub_child_dir.parts:
          # print('part', part)
          if part == 'Downloads':
              new_parts.append('Downloads-Processed')  # Replace 'Downloads' with 'Downloads-Processed'
          else:
              new_parts.append(part)

      # Construct the new destination path
      dest_sub_child_dir = Path(*new_parts)

      # Print the destination path
      print(dest_sub_child_dir)

      if not dest_sub_child_dir.parent.exists():
        dest_sub_child_dir.parent.mkdir(exist_ok=True)
        print('Created dir', dest_sub_child_dir.parent)

      sub_child_dir.rename(dest_sub_child_dir)

      # exit()


      # now = datetime.now()
      # formatted_time = now.strftime('%Y%m%d%H%M')
      # process = subprocess.Popen([
      #   '/cygdrive/c/rclone/rclone.exe',
      #   'move',
      #   '-vv',
      #   '--dry-run',
      #   '--local-encoding=None',
      #   '--backup-dir=b2-phill-all:Archive-Store/_/Staging/Laptop/Downloads-Backup/' + formatted_time,
      #   '.',
      #   'b2-phill-all:Archive-Store/_/Staging/Laptop/Downloads'
      # ], cwd=sub_child_dir, stdout=subprocess.PIPE)
      # for c in iter(lambda: process.stdout.read(1), b""):
      #   sys.stdout.buffer.write(c)

















