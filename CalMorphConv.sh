#!/usr/bin/env bash

DIR=/Volumes/X2/test
NUM_FIELDS=40
NUM_CHANNELS=2
CSV_FILE='test.csv'
NUM_WELLS=384

# Filename Options
FILE_PREFIX='xy'
FILE_ZERO_PADDING=5
FILE_CHANNEL_SEP='c'
FILE_TIF_EXT='tif'
FILE_JPEG_EXT='jpeg'

# Default to 384 well plates
NUM_ROWS=16
NUM_COLS=24
if [ $NUM_WELLS == 96 ]; then
  NUM_ROWS=8
  NUM_COLS=12
fi

# Optionally take rows and cols on command line

# Check for libtiff and instruct otherwise

# Check for sip and instruct otherwise

# Read the .csv file into an array, first skipping the header row
# and then grabbing the 3rd column of the file.
genotypes=( $(tail -n+2 $CSV_FILE | cut -d ',' -f3 ) )

# Helper function to 
genotype_index () {
  return $(($NUM_COLS * $1 + $2))
}

# Stop doing this: just construct the file name directly
# Read all files into an array
#files=($DIR/*.$FILE_EXT)

# Iterate through every well by row and col
for (( row=0; row < $NUM_ROWS; row++ ))
do
  for (( col=0; col < $NUM_COLS; col++ ))
  do
    # Lookup the genotype for this well by
    # mapping [row][col] to an index in our 1d array
    genotype_index=$((NUM_COLS * row + col))
    genotype=${genotypes[$genotype_index]}

    # Map a row, col, field, and channel to a file.
    # This is a bit strange as the microscope processes the first column
    # first and then loops back and forth through the remainder of the rows
    # going from bottom to top.
    
    # We start by calculating the number of wells that are before the one
    # we are currently processing. This is dependent on row and col only,
    # so we pull this code out of the inner loop.
    
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
    echo "wells: $num_wells"
    echo "genotype: $genotype"
    	
    # Further iterate through every field and channel for that well
    for (( field=1; field <= $NUM_FIELDS; field++ ))
    do
      # Construct the filename's base now since it's not dependent on the channel.
      # See http://wiki.bash-hackers.org/commands/builtin/printf#modifiers
      # for documentation on printf formatting.
      printf -v basename "%s%0*d%s" $FILE_PREFIX $FILE_ZERO_PADDING \
          $(( num_prev_files + field )) $FILE_CHANNEL_SEP
      
      for (( channel=1; channel <= $NUM_CHANNELS; channel++ ))
      do
        # Append the channel number to get the full filename (-extension)
    	  filename=$basename$channel
      	echo "filename: $filename"
      done
    done
  done
done

#tiffcrop -U px -z 1,1,100,100:101,1,200,100:201,1,300,100 -e separate test.tif new