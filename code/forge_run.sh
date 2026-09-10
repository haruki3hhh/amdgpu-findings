#!/bin/bash
S=/tmp/claude-1000/-home-hotaisle-linux/76d33b55-b8ba-48f1-9857-4673258a09ed/scratchpad
FIELD=$1; VAL=$2; MASK=$3; N=${4:-12}; IT=${5:-150000000}
for i in $(seq 1 $N); do ( timeout 150 $S/cwsr_forge $FIELD $VAL $MASK $IT > $S/fg_${i}.txt 2>&1 ) & done
wait
# show the run that patched the most (best evidence)
echo "### field=$FIELD val=$VAL mask=$MASK  (N=$N) ###"
for i in $(seq 1 $N); do
  p=$(grep -oE "patched=[0-9]+" $S/fg_${i}.txt | cut -d= -f2)
  echo "$p $i"
done | sort -rn | head -1 | while read p i; do
  echo "-- best evidence: instance $i (patched=$p) --"
  cat $S/fg_${i}.txt
done
