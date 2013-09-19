#!/usr/bin/env bash

# This script converts a directory of large, sequential TIFF files into smaller
# JPEGs, storing them in a directory structure, for use with CalMorph.

##
# Defaults for Command Line Arguments (checked below)
##

# CSV Defaults
CSV_FILE= # The plate id file in .csv format (no default)
SEARCH_IN_DIR_FOR_CSV=false # Don't search $IN_DIR for .csv files by default

# Input File Defaults
IN_DIR="." # The directory where the tiff images are stored (current dir)
IN_FILENAME_PREFIX="xy"
IN_FILENAME_ZERO_PADDING=5 # Number of total digits, padded with 0s (TD: switch to calculating)
IN_FILENAME_CHANNEL_SEP="c" # This separates the sequence # from the channel #
IN_FILENAME_EXT="tif" # Must be an image type

# Output File Defaults
OUT_DIR= # Defaults to IN_DIR if not set (below after processing command line)
OUT_GROUP_PREFIX="1_" # e.g., '1_' (also applied to genotype directory)
OUT_GROUP_SUFFIX="proc" # e.g., 'proc' (also applied to genotype directory)
OUT_FILENAME_CHANNEL=([1]=C [2]=D [3]=A) # array mapping a channel to its CalMorph symbol
OUT_FILENAME_EXT="jpg" # Must be an image type
OUT_IMG_WIDTH=696
OUT_IMG_HEIGHT=520
OUT_IMG_DEPTH=8
OUT_OVERWRITE=false

# Microscope Defaults
MICROSCOPE="cobra" # The microscope being used (cobra, joe, or custom)
NUM_WELLS=384 # The number of wells (384 or 96)
NUM_FIELDS=40 # Usually computed based on input files
NUM_CHANNELS=2 # The number of channels

# Parallel Defaults
NUM_JOBS="+0"

# ImageMagick Defaults
CONTRAST="none"

# Custom Microscope
CUSTOM_IM=
CUSTOM_IM_NUM_OUTPUT_IMGS=
CUSTOM_INPUT_BIT_DEPTH=

# Misc Options
QUIET=false # Do not warn (e.g., when expected .tiff file is not found)
WELL_ROW_NAMES=({A..Z}) # rows are referenced by letter

# Helper function for printing human readable wells
printWell() { # row, col
  echo "${WELL_ROW_NAMES[$1]}$(($2+1))"
}

# TD
# Add code to determine the padding
# Preemptively bring files into the cache?
# add histogram and auto-level switch, maybe as 'c' with different settings
# move row,col => index to function
# add support for joe
# add nice well printouts

##
# Command Line Usage and Parsing
##

usage() { 
  echo "
Usage: $0 [-i input_directory] [-m cobra|joe] [-w 384|96] [options ...] [-p] plate_id.csv

Example: $0 -i path_to_tiffs/ -p plate_id.csv

Input & Output Options
  -i input_directory    directory of TIFF files (current directory)
  -a input_prefix       input file prefix ($IN_FILENAME_PREFIX)
  -o output_directory   output directory for JPEGs (= input dir if not set)
  -A group_prefix       group prefix applied to output files and dirs ($OUT_GROUP_PREFIX)
  -Z group_suffix       group suffix applied to output files and dirs ($OUT_GROUP_SUFFIX)

Microscope Options
  -m cobra|joe|custom   specify microscope ($MICROSCOPE)
  -w 384|96             number of wells, which is either 384 or 96 ($NUM_WELLS)
  -f num_fields         number of fields (images per well) (this value is
                        usually automatically computed based on # of tiffs)
  -c num_channels       number of channels (wall, nucleus, actin) ($NUM_CHANNELS)

Plate ID Options
  [-p] plate_id.csv     the plate id file (must be last argument w/t flag)
  -P                    automatically search input_directory for a .csv plate
                        id file (use in place of -p) (requires extension)

GNU Parallel Options
  -j num_jobs           number of jobs to run in parallel (e.g., 3 or +4) ($NUM_JOBS)

ImageMagick Options
  -C none|auto|norm     specify contrast algorithm by channel

Custom Microscope
  -M custom_im          allows custom image cropping when microscope (-m)
                        is \"custom\"
  -n custom_out_imgs    number of output images generated when microscope (-m)
                        is \"custom\"
  -b custom_bit_depth   custom bit depth when microscope (-m) is \"custom\"

Misc Options
  -O                    overwrite output files
  -q                    quiet (e.g., do not print missing input file warnings)
  -v                    verbose (print all commands)
  -h                    help
" >&2
  exit 1
}

# Check command line parameters
while getopts ":i:a:o:A:Z:m:w:f:c:p:Pj:C:M:n:b:Oqvh" opt; do
  case $opt in
    i)
      IN_DIR="$OPTARG"
      ;;
    a)
      IN_FILENAME_PREFIX="$OPTARG"
      ;;
    o)
      OUT_DIR="$OPTARG"
      ;;
    A)
      OUT_GROUP_PREFIX="$OPTARG"
      ;;
    Z)
      OUT_GROUP_SUFFIX="$OPTARG"
      ;;
    m)
      MICROSCOPE="$OPTARG"
      ;;
    w)
      NUM_WELLS="$OPTARG" # checked below
      ;;
    f)
      NUM_FIELDS="$OPTARG"
      ;;
    c)
      NUM_CHANNELS="$OPTARG"
      ;;
    p)
      CSV_FILE="$OPTARG"
      ;;
    P)
      SEARCH_IN_DIR_FOR_CSV=true # IN_DIR may not be set correctly, so just flag
      ;;
    j)
      NUM_JOBS="$OPTARG"
      ;;
    C)
      echo "Got $OPTARG"
      ;;
    M)
      CUSTOM_IM="$OPTARG"
      ;;
    b)
      CUSTOM_INPUT_BIT_DEPTH="$OPTARG"
      ;;
    O)
      OUT_OVERWRITE=true
      ;;
    q)
      QUIET=true
      ;;
    v)
      set -x
      ;;
    h)
      usage
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      usage
      ;;
    :)
      echo "Option -$OPTARG requires an argument." >&2
      usage
      ;;
  esac
done
shift $(( OPTIND-1 )) # must shift the positional parameter set after getopts

##
# Check for Required Programs
##

# Check for ImageMagick
if ! hash convert 2>/dev/null; then
  echo "
This script requires ImageMagick to run. On Mac OS X, this can be
installed using \"Homebrew\" (http://brew.sh, see one line install
insruction toward the bottom of the page). With brew,

  brew install imagemagick --with-libtiff

Using jpeg-turbo (instead of jpeg) can further improve performance,

  brew uninstall libtiff jpeg   (if either are installed)
  brew install jpeg-turbo
  brew link --force jpeg-turbo
  brew install libtiff
  brew install imagemagick --with-libtiff --without-jpeg
  " >&2
  exit 1
fi

# Check for GNU Parallel
if ! hash sem 2>/dev/null; then
  echo "
Installing GNU Parallel will generally improve performance,
even when using an external drive:

  brew install parallel
    " >&2
    exit 1
fi

##
# Configure Settings
##

# Convert the number of wells to rows and columns
case "$NUM_WELLS" in
  96)
    NUM_ROWS=8
    NUM_COLS=12
    ;;
  384)
    NUM_ROWS=16
    NUM_COLS=24
    ;;
  *)
    echo "Unknown \"number of wells\" argument $NUM_WELLS. Expecting 96 or 384." >&2
    exit 1;
    ;;
esac

# Check if OUT_DIR is set and set to IN_DIR if not
if [[ -z $OUT_DIR ]]; then
  OUT_DIR="$IN_DIR"
fi

# Configure settings based on microscope
im_process_image=()
im_num_out_imgs=1
im_input_bit_depth=8
case "$MICROSCOPE" in
  cobra)
    #in_img_width=2560
    in_img_height=2160
    # We need to shave some pixels off the top and bottom to be able to evenly
    # divide it up. (We prefer the interior to the edges.)
    # Some dark "magick," but note that bash does int div and will truncate
    # TD: Explain (especially why it's rotated)
    im_process_image+=(-shave 0x$(( (in_img_height - in_img_height/OUT_IMG_WIDTH * OUT_IMG_WIDTH)/2 )))
    # TD: Explain
    im_process_image+=(-crop "5x3+10+0@")
    im_process_image+=(+repage)
    im_process_image+=(+adjoin)
    # TD: Explain rotation (and slightly faster)
    im_process_image+=(-rotate 90)
    im_num_out_imgs=15
    im_input_bit_depth=11
    ;;
  joe)
    #in_img_width=1392
    #in_img_height=1040
    im_process_image+=(-crop "2x2")
    im_process_image+=(+repage)
    im_process_image+=(+adjoin)
    im_num_out_imgs=4
    im_input_bit_depth=12
    ;;
  custom)
    if [[ ! -z $CUSTOM_IM && -z $CUSTOM_IM_NUM_OUTPUT_IMGS && ! -z $CUSTOM_INPUT_BIT_DEPTH ]]; then
      echo "When using a custom microscope, -M, -n, and -b must be passed."
      exit 1
    else
      im_process_image="$CUSTOM_IMG"
      im_num_out_imgs="$CUSTOM_IM_NUM_OUTPUT_IMGS"
      im_input_bit_depth="$CUSTOM_INPUT_BIT_DEPTH"
    fi
    ;;
  *)
    echo "Unknown microscope $MICROSCOPE. Expecting cobra, joe, or custom." >&2
    exit 1
esac

# Configure ImageMagick contrast settings
case "$CONTRAST" in
  none)
    ;;
  auto)
    ;;
  norm)
    ;;
  *)
    ;;
esac
#"-evaluate Multiply 32" # "-auto-level" "-normalize"

##
# Process CSV Plate ID File
##

# Check to see if our .csv is set from a "-p plate_ID.csv" switch
if [[ -z $CSV_FILE ]]; then
  # If not, try to grab it off the command line
  if (( $# > 0 )); then
    CSV_FILE="$1"
  elif $SEARCH_IN_DIR_FOR_CSV; then # -P was passed
    # If it's also not on the command line, we'll look for one in the file dir
    csvs=($IN_DIR/*.csv)
    if (( ${#csvs[@]} > 0 )); then
      CSV_FILE=${csvs[0]}
    else
      echo "No .csv plate ID file was found in $IN_DIR."
      echo "Does the plate id file not have a .csv extension?"
      exit 1
    fi
  fi
fi
# Final check for .csv plate ID file
if [[ -z $CSV_FILE || ! -f $CSV_FILE ]]; then
  echo "No .csv plate ID file was found."
  usage
fi

# Convert .csv line endings from CR (Mac Classic) or CRLF (Windows)
# to LF (Mac/Unix). We do this because Excel on Mac saves .csv files
# with CR line endings for some bizarre reason. (Just run it every
# time.)
perl -i -pe 's/\r\n?/\n/g' $CSV_FILE

# Read the .csv file into an array, first skipping the header row
# and then grabbing the 3rd column. This places all of our genotypes 
# in a single array matching the column from the .csv file.
genotypes=( $(tail -n+2 $CSV_FILE | cut -d ',' -f3 ) )

##
# Main Loop: Iterate through every well by row and col
##
for (( row=0; row < $NUM_ROWS; row++ ))
do
  for (( col=0; col < $NUM_COLS; col++ ))
  do
    # Print status (note: only integer arithmetic)
    completion_percentage=$(( 100 * (NUM_COLS * row + col) / (NUM_COLS * NUM_ROWS) ))
    echo "Processing well $(printWell $row $col) ($completion_percentage%)"
    
    # Look up the genotype for this well by mapping [row][col] to an index in
    # our 1d array. This just maps the 2d matrix of rows and cols to our 1d
    # list of genotypes.
    genotype_index=$(( NUM_COLS * row + col ))
    genotype=${genotypes[$genotype_index]}
    
    # Count the number of times we have already seen this genotype.
    # This is used to calculate the output filename's sequence # below.
    # We do this because there can be multiple wells with the same genotype,
    # but the output images for ALL wells must still be sequenced from 1 to N.
    num_prev_wells_of_same_genotype=0
    for (( gi=0; gi < $genotype_index; gi++ ))
    do
      if [[ "${genotypes[gi]}" = "$genotype" ]]; then
        (( num_prev_wells_of_same_genotype++ ))
      fi
    done
    
    # Create an output directory if not already present
    out_dir="$OUT_DIR/$OUT_GROUP_PREFIX$genotype$OUT_GROUP_SUFFIX"
    if [[ ! -d $out_dir ]]; then
      mkdir -p "$out_dir"
    fi

    # Map a row, col, field, and channel to a file.
    # This is a bit strange as the microscope processes the first column
    # first and then loops back and forth through the remainder of the rows
    # going from bottom to top.
    
    # We start by calculating the number of wells that are before the one
    # we are currently processing. This is dependent on row and col only,
    # so we pull this code out of the inner loop.
    
    # First, start by counting the number of wells that come before it
    if (( $col == 0 )); then
      # Still in the first column, so this is just the number of rows 
      # above the current well
    	num_prev_wells=$row
    else
      # Already moved beyond the first column, so include it all
    	num_prev_wells=$NUM_ROWS

    	# Also include every row that's already been processed:
    	# number of rows (except ours) * number of columns (except the first,
    	# which has already been counted)
    	(( num_prev_wells += (NUM_ROWS-row-1) * (NUM_COLS-1) ))

      # Explain even and zero indexing
    	if ! ((row % 2)); then
    		# The row is even, so we include every well AFTER it
    		# (Microscope is heading back to the left.)
    		(( num_prev_wells += NUM_COLS-col-1 ))
    	else
    		# The row is odd, so we include every well BEFORE it,
    		# except the first, which has already been counted
    		# (Microscope is heading right.)
    		(( num_prev_wells += col-1 ))
    	fi
    fi
    
    # The number of previous files is then num_wells * the number
    # of files per well (NUM_FIELDS)
    # Note: We do not include NUM_CHANNELS here as we're constructing
    #       the filename, and the channel # is just appended.
    num_prev_files=$(( num_prev_wells * NUM_FIELDS ))
    
    # Further iterate through every field and channel for that well
    for (( field=1; field <= $NUM_FIELDS; field++ ))
    do
      # Construct the filename's base now since it's not dependent on the channel.
      # See http://wiki.bash-hackers.org/commands/builtin/printf#modifiers
      # for documentation on printf formatting.
      printf -v in_basename "%s%0*d%s" $IN_FILENAME_PREFIX $IN_FILENAME_ZERO_PADDING \
          $(( num_prev_files + field )) $IN_FILENAME_CHANNEL_SEP
          
      # Calculate the output filename's sequence #:
      # CalMorph expects the JPEGs to have sequence numbers from 1 up
      # (e.g., -C1, -C2, -C3, ...). IM will split up a single input image
      # into multiple, smaller output images, but for the output filenames
      # to be correct, we must tell IM where to start counting, which means
      # that we must calculate the number of output images that come before
      # the current image.
      seq_num=$(( num_prev_wells_of_same_genotype*NUM_FIELDS*im_num_out_imgs + \
        (field-1)*im_num_out_imgs + 1 ))
      
      for (( channel=1; channel <= $NUM_CHANNELS; channel++ ))
      do
        # Append the channel number to get the full filename (-extension)
    	  in_filename="$in_basename$channel.$IN_FILENAME_EXT"
    	  
    	  # Check to see if the input file exists
    	  if [[ -f $IN_DIR/$in_filename ]]; then
      	  # Output filename (must escape %d to pass to IM)
        	printf -v out_filename "%s%s%s-%s%%d.%s" \
        	  "$OUT_GROUP_PREFIX" "$genotype" "$OUT_GROUP_SUFFIX" \
        	  "${OUT_FILENAME_CHANNEL[$channel]}" "$OUT_FILENAME_EXT"
      	  
      	  # Check to see if the output files already exist and skip if they ALL do
      	  # (Again, each input file becomes $im_num_out_imgs.)
      	  for (( seq=$seq_num; seq < $seq_num + $im_num_out_imgs; seq++ ))
          do
      	    printf -v out_filename_seq "$out_filename" $seq
      	    if [[ ! -f $out_dir/$out_filename_seq ]] || $OUT_OVERWRITE; then
          	  # Run ImageMagick's "convert" using GNU Parallel's "sem."
          	  # This allows running up to $NUM_JOBS in the background.
            	sem -j "$NUM_JOBS" --id $$ -q convert "$IN_DIR/$in_filename" -quiet \
            	    -auto-level -depth $OUT_IMG_DEPTH "${im_process_image[@]}" \
            	    -scene $seq_num "$out_dir/$out_filename"
            	break # IM will generate all $im_num_out_imgs at the same time
            fi
          done
      	elif ! $QUIET; then
      	  echo "File \"$IN_DIR/$in_filename\" does not exist (well: $(printWell $row $col), genotype: $genotype)."
        fi
      done
    done
  done
done
sem --wait # join all threads

# chr() - converts decimal value to its ASCII character representation
chr() {
  printf \\$(printf '%03o' $1)
}

# ord() - converts ASCII character to its decimal value
ord() {
  printf '%d' "'$1"
}

#row_to_char() {
  #A_ord=$(ord A)
  #echo "$A_ord"
  #row_ord=((  A_ord + $1 ))
  #chr row_ord
#}

clean_up() {
	sem --wait # join all threads
	exit
}

trap clean_up SIGHUP SIGINT SIGTERM