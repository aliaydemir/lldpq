#!/bin/bash
# Test script to verify SSH-FAILED device detection
# This simulates a device that pings but SSH fails

echo "🧪 Testing SSH-FAILED device detection..."
echo "========================================="

cd ~/monitor/

# Create a test assets.ini with SSH-FAILED entry
cat > test_assets.ini << EOF
Created on $(date '+%Y-%m-%d %H-%M-%S')

DEVICE-NAME          IP               ETH0-MAC          SERIAL       MODEL        RELEASE  UPTIME
test-device          192.168.1.100    SSH-FAILED        SSH-FAILED   SSH-FAILED   SSH-FAILED SSH-FAILED
Border1              10.10.100.101    aa:bb:cc:dd:ee:ff SN12345      SwitchModel  5.4.0    up-2-days
EOF

# Copy to web directory for testing
sudo cp test_assets.ini /var/www/html/assets.ini

echo "✅ Test file created: /var/www/html/assets.ini"
echo ""
echo "🌐 Now check the web interface:"
echo "   - Go to your LLDPq dashboard"
echo "   - Click on 'DEVICES' in the sidebar"
echo "   - You should see 'test-device' with 'SSH FAILED' status in PINK/MAGENTA color"
echo ""
echo "🔍 Expected behavior:"
echo "   - Device count: 2 total"
echo "   - Success: 1 (Border1)"
echo "   - SSH Failed: 1 (test-device) - shown as WARNING"
echo ""
echo "🧹 To restore original assets.ini:"
echo "   cd ~/monitor && ./assets.sh"
echo ""
