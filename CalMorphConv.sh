#!/usr/bin/env bash

# This script converts a directory of large, sequential TIFF files to smaller
# JPEGs, storing them in a directory structure, for use with CalMorph.

# Defaults for Command Line Arguments (checked below)
CSV_FILE= # The plate id file in .csv format
DIR="." # The directory where the tiff images are stored
NUM_WELLS=384 # The number of wells (384 or 96)
NUM_CHANNELS=2 # The number of channels
SEARCH_IN_DIR_FOR_CSV=false # Don't search DIR for .csv files by default

NUM_FIELDS=40 # TD: compute on the fly

# Input File Options
IN_FILENAME_PREFIX='xy'
IN_FILENAME_ZERO_PADDING=5 # Number of total digits, padded with 0s (TD: switch to calculating)
IN_FILENAME_CHANNEL_SEP='c' # This separates the sequence # from the channel #
IN_FILENAME_EXT='tif' # Must be an image type
IN_IMG_WIDTH=2560
IN_IMG_HEIGHT=2160

# Output File Options
OUT_FILENAME_PREFIX='' # e.g., '1_'
OUT_FILENAME_SUFFIX='' # e.g., 'proc'
OUT_FILENAME_CHANNEL=([1]=C [2]=D) # array mapping a channel to its CalMorph symbol
OUT_FILENAME_EXT='jpg' # Must be an image type
OUT_IMG_WIDTH=696
OUT_IMG_HEIGHT=520
OUT_IMG_DEPTH=8

# Output Directory Options
OUT_DIR_PREFIX='' # e.g., '1_'
OUT_DIR_SUFFIX='' # e.g., 'proc'

# ImageMagick Options
IM_APP="convert"
IM_QUIET="-quiet"
IM_CONTRAST="-evaluate Multiply 32" # "-auto-level"
IM_DEPTH="-depth $OUT_IMG_DEPTH"
# We need to shave some pixels off the top and bottom to be able to evenly
# divide it up. (We prefer shaving the edges.)
# Some dark "magick," but note that bash does int div and will truncate
# TD: Explain (especially why it's rotated)
IM_SHAVE="-shave 0x$(( (IN_IMG_HEIGHT - IN_IMG_HEIGHT/OUT_IMG_WIDTH * OUT_IMG_WIDTH)/2 ))"
# TD: Explain
IM_CROP="-crop 5x3+10+0@ +repage +adjoin"
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

# Check command line parameters
while getopts ":d:w:c:p:Ph" opt; do
  case $opt in
    d)
      DIR="$OPTARG"
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
      SEARCH_IN_DIR_FOR_CSV=true # DIR may not be set correctly, so just flag
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
    echo "search code"
    csvs=($DIR/*.csv)
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
    # Lookup the genotype for this well by
    # mapping [row][col] to an index in our 1d array
    genotype_index=$(( NUM_COLS * row + col ))
    genotype=${genotypes[$genotype_index]}
    
    # Print status
    completion_percentage=$(( 100 * (NUM_COLS * row + col) / (NUM_COLS * NUM_ROWS) ))
    echo "Processing well ${row}x${col} ($completion_percentage%)"
    
    # Create an output directory if not already present
    out_dir="$DIR/$OUT_DIR_PREFIX$genotype$OUT_DIR_SUFFIX"
    if [ ! -d "$out_dir" ]; then
      mkdir "$out_dir"
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
    if [ $col == 0 ]; then
      # Still in the first column, so this is just the number of rows 
      # above the current well
    	num_wells=$row
    else
      # Already moved beyond the first column, so include it all
    	num_wells=$NUM_ROWS

    	# Also include every row that's already been processed:
    	# number of rows (except ours) * number of columns (except the first,
    	# which has already been counted)
    	(( num_wells += (NUM_ROWS-row-1) * (NUM_COLS-1) ))

      # Explain even and zero indexing
    	if ! ((row % 2)); then
    		# If the row is even, we include every well after it
    		# (Microscope is heading back to the left.)
    		(( num_wells += NUM_COLS-col-1 ))
    	else
    		# The row is odd, so we include every well before it
    		# except the first, which has already been counted
    		# (Microscope is heading right.)
    		(( num_wells += col-1 ))
    	fi
    fi
    
    # The number of previous files is then num_wells * the number
    # of files per well (NUM_FIELDS)
    # Note: We do not include NUM_CHANNELS here as we're constructing
    #       the filename, and the channel is just appended.
    num_prev_files=$(( num_wells*NUM_FIELDS ))
    	
    # Further iterate through every field and channel for that well
    for (( field=1; field <= $NUM_FIELDS; field++ ))
    do
      # Construct the filename's base now since it's not dependent on the channel.
      # See http://wiki.bash-hackers.org/commands/builtin/printf#modifiers
      # for documentation on printf formatting.
      printf -v in_basename "%s%0*d%s" $IN_FILENAME_PREFIX $IN_FILENAME_ZERO_PADDING \
          $(( num_prev_files + field )) $IN_FILENAME_CHANNEL_SEP
      
      for (( channel=1; channel <= $NUM_CHANNELS; channel++ ))
      do
        # Append the channel number to get the full filename (-extension)
    	  in_filename=$in_basename$channel.$IN_FILENAME_EXT
    	  
    	  if [ -e "$DIR/$in_filename" ]; then
      	  # Output filename
        	# Must escape the %02d being passed on to ImageMagick
        	printf -v out_filename "%s%s%s-%s%02d%02d%03d%%02d.%s" \
        	  "$OUT_FILENAME_PREFIX" "$genotype" "$OUT_FILENAME_SUFFIX" \
        	  "${OUT_FILENAME_CHANNEL[$channel]}" "$row" "$col" "$field" "$OUT_FILENAME_EXT"
      	  
      	  # add check to see if file exists
      	  
        	# Run ImageMagick on the tiff input file:
        	#   - Normalize the 
        	cmd="$IM_APP $DIR/$in_filename $IM_ALL_COMMANDS $out_dir/$out_filename"
        	$cmd
      	else
      	  echo "$DIR/$in_filename does not exist. Well: ${row}x${col} Genotype: $genotype"
        fi
      done
    done
  done
done

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