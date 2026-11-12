#!/bin/sh
# Temporarily set the sleep mode to deep and suspend the system.
echo "Attempting to set sleep mode to deep and suspend..."
echo deep > /sys/power/mem_sleep && systemctl suspend
