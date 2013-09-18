#!/usr/bin/env bash

# This script converts a directory of large, sequential TIFF files into smaller
# JPEGs, storing them in a directory structure, for use with CalMorph.

#
# Defaults for Command Line Arguments (checked below)
#

# CSV Defaults
CSV_FILE= # The plate id file in .csv format (no default)
SEARCH_IN_DIR_FOR_CSV=false # Don't search IN_DIR for .csv files by default

# Input File Defaults
IN_DIR="." # The directory where the tiff images are stored
IN_FILENAME_PREFIX='xy'
IN_FILENAME_ZERO_PADDING=5 # Number of total digits, padded with 0s (TD: switch to calculating)
IN_FILENAME_CHANNEL_SEP='c' # This separates the sequence # from the channel #
IN_FILENAME_EXT='tif' # Must be an image type
IN_IMG_WIDTH=2560
IN_IMG_HEIGHT=2160

# Output File Options
OUT_DIR= # Defaults to IN_DIR if not set (below after processing command line)
OUT_DIR_PREFIX='1_' # e.g., '1_'
OUT_DIR_SUFFIX='proc' # e.g., 'proc'
OUT_FILENAME_PREFIX='1_' # e.g., '1_'
OUT_FILENAME_SUFFIX='proc' # e.g., 'proc'
OUT_FILENAME_CHANNEL=([1]=C [2]=D) # array mapping a channel to its CalMorph symbol
OUT_FILENAME_EXT='jpg' # Must be an image type
OUT_IMG_WIDTH=696
OUT_IMG_HEIGHT=520
OUT_IMG_DEPTH=8

# Misc Defaults
NUM_WELLS=384 # The number of wells (384 or 96)
NUM_CHANNELS=2 # The number of channels
QUIET=false # Do not warn (e.g., when expected .tiff file is not found)
NUM_FIELDS=40 # TD: compute on the fly

# ImageMagick Defaults
IM_APP="convert"
IM_QUIET="-quiet"
IM_CONTRAST="-evaluate Multiply 32" # "-auto-level" # "-normalize"
IM_DEPTH="-depth $OUT_IMG_DEPTH"
# We need to shave some pixels off the top and bottom to be able to evenly
# divide it up. (We prefer shaving the edges.)
# Some dark "magick," but note that bash does int div and will truncate
# TD: Explain (especially why it's rotated)
IM_SHAVE="-shave 0x$(( (IN_IMG_HEIGHT - IN_IMG_HEIGHT/OUT_IMG_WIDTH * OUT_IMG_WIDTH)/2 ))"
# TD: Explain
IM_CROP="-crop 5x3+10+0@ +repage +adjoin"
IM_NUM_OUT_IMGS=15
# TD: Explain rotation
IM_ROTATE="-rotate 90"
IM_ALL_COMMANDS="$IM_QUIET $IM_CONTRAST $IM_DEPTH $IM_SHAVE $IM_CROP $IM_ROTATE"

# TD
#overlap=10
# Add code to determine the padding
# Do line conversion automatically
# Fix ugly IM code and calculate tiling automatically
# Fix space in directories and filenames
# Convert .csv file to proper line endings
# Preemptively bring files into the cache?
# multi-thread?
# Add bit depth flag and calculate multiplication
# add overwrite flag to overwrite files
# add verbose flag and use for else when file exists
# add a command line argument for parallel
# add support for Jpg_Folders
# add histogram and auto-level switch, maybe as 'c' with different settings
# move row,col => index to function
 
# Check command line parameters
while getopts ":d:w:c:p:Pqh" opt; do
  case $opt in
    d)
      IN_DIR="$OPTARG"
      ;;
    w)
      NUM_WELLS="$OPTARG"
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
    q)
      QUIET=true
      ;;
    h)
      echo "-h was triggered, Parameter: $OPTARG" >&2
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      exit 1
      ;;
    :)
      echo "Option -$OPTARG requires an argument." >&2
      exit 1
      ;;
  esac
done
shift $(( OPTIND-1 )) # must shift the positional parameter set after getopts

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
    echo "Unknown \"number of wells\" argument. Expecting 384 or 96."
    exit 1;
    ;;
esac

# Check to see if our .csv is set
if [ -z "$CSV_FILE" ]; then
  # If not, try to grab it off the command line
  if (( $# > 0 )); then
    CSV_FILE="$1"
  elif $SEARCH_IN_DIR_FOR_CSV; then # -P was passed
    # If it's also not on the command line, we'll look for one in the file dir
    csvs=($IN_DIR/*.csv)
    if (( ${#csvs[@]} > 0 )); then
      CSV_FILE=${csvs[0]}
    else
      # TD: print usage
      echo "No .csv file was found."
      exit 1
    fi
  else
    # TD: print usage
    echo "No .csv file was found."
    exit 1
  fi
fi

# Check if OUT_DIR is set and set to IN_DIR if not
if [ -z "$OUT_DIR" ]; then
  OUT_DIR="$IN_DIR"
fi

# Check for imagemagick and instruct otherwise
# brew install imagemagic --with-libtiff

# Read the .csv file into an array, first skipping the header row
# and then grabbing the 3rd column.
# Explain 1d array
genotypes=( $(tail -n+2 $CSV_FILE | cut -d ',' -f3 ) )

# Iterate through every well by row and col
for (( row=0; row < $NUM_ROWS; row++ ))
do
  for (( col=0; col < $NUM_COLS; col++ ))
  do
    # Print status (note: only integer arithmetic)
    completion_percentage=$(( 100 * (NUM_COLS * row + col) / (NUM_COLS * NUM_ROWS) ))
    echo "Processing well ${row}x${col} ($completion_percentage%)"
    
    # Lookup the genotype for this well by
    # mapping [row][col] to an index in our 1d array
    genotype_index=$(( NUM_COLS * row + col ))
    genotype=${genotypes[$genotype_index]}
    
    # Count the number of times we have already seen this genotype.
    # This is used to calculate the output filename's sequence # below.
    num_prev_wells_of_same_genotype=0
    for (( gi=0; gi < $genotype_index; gi++ ))
    do
      if [ "${genotypes[gi]}" = "$genotype" ]; then
        (( num_prev_wells_of_same_genotype++ ))
      fi
    done
    
    # Create an output directory if not already present
    out_dir="$OUT_DIR/$OUT_DIR_PREFIX$genotype$OUT_DIR_SUFFIX"
    if [ ! -d "$out_dir" ]; then
      mkdir -p "$out_dir"
    fi

    # Map a row, col, field, and channel to a file.
    # This is a bit strange as the microscope processes the first column
    # first and then loops back and forth through the remainder of the rows
    # going from bottom to top.
    
    # We start by calculating the number of wells that are before the one
    # we are currently processing. This is dependent on row and col only,
    # so we pull this code out of the inner loop.
    
    # TO DO: change to num_prev_wells
    
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
      seq_num=$(( num_prev_wells_of_same_genotype*NUM_FIELDS*IM_NUM_OUT_IMGS + \
        (field-1)*IM_NUM_OUT_IMGS + 1 ))
      
      for (( channel=1; channel <= $NUM_CHANNELS; channel++ ))
      do
        # Append the channel number to get the full filename (-extension)
    	  in_filename="$in_basename$channel.$IN_FILENAME_EXT"
    	  
    	  # Check to see if the input file exists
    	  if [ -e "$IN_DIR/$in_filename" ]; then
      	  # Output filename (must escape %d to pass to IM)
        	printf -v out_filename "%s%s%s-%s%%d.%s" \
        	  "$OUT_FILENAME_PREFIX" "$genotype" "$OUT_FILENAME_SUFFIX" \
        	  "${OUT_FILENAME_CHANNEL[$channel]}" "$OUT_FILENAME_EXT"
      	  
      	  # Check to see if the output files already exist and skip if they ALL do
      	  for (( seq=$seq_num; seq < $seq_num + $IM_NUM_OUT_IMGS; seq++ ))
          do
      	    printf -v out_filename_seq "$out_filename" $seq
      	    if [ ! -f "$out_dir/$out_filename_seq" ]; then
      	      # Run ImageMagick on the tiff input file:
            	#   - Normalize the 
            	cmd="$IM_APP $IN_DIR/$in_filename $IM_ALL_COMMANDS -scene $seq_num $out_dir/$out_filename"
            	echo $cmd
            	1sem -j7 $cmd
            	break # IM will generate all IM_NUM_OUT_IMGS at the same time
            fi
          done
      	elif ! $QUIET; then
      	  echo "File \"$IN_DIR/$in_filename\" does not exist (well: ${row}x${col}, genotype: $genotype)."
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