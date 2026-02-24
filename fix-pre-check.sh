#!/bin/bash
set -e
set -x
 
# === 1. Install Required Packages (all in one) ===
yum install -y nscd bind-utils sssd openldap-clients krb5-workstation krb5-libs adcli realmd oddjob rng-tools
 
# === 2. Disable Firewalld (only if exists) ===
if systemctl is-active firewalld &>/dev/null; then
	    systemctl stop firewalld
	        systemctl disable firewalld
	else
		    echo "Firewalld not active or not installed. Skipping."
fi
 
# === 3. Set SELinux to Permissive (safe check) ===
SESTATUS=$(sestatus 2>/dev/null)
if echo "$SESTATUS" | grep -q "SELinux status: enabled"; then
	    setenforce 0 || echo "Warning: Could not set SELinux to permissive."
	        sed -i 's/SELINUX=enforcing/SELINUX=permissive/g' /etc/selinux/config
		    echo "SELinux set to permissive."
	    else
		        echo "SELinux is disabled or already in permissive mode. Skipping."
fi
 
# === 4. Configure sysctl (no duplicates) ===
SYSCTL_FILE="/etc/sysctl.conf"
 
declare -a sysctl_lines=(
    "net.ipv6.conf.all.disable_ipv6 = 1"
        "net.ipv6.conf.default.disable_ipv6 = 1"
	    "vm.overcommit_memory=1"
	        "vm.swappiness=1"
	)
	 
	for line in "${sysctl_lines[@]}"; do
		    if ! grep -q "^$line$" "$SYSCTL_FILE"; then
			            echo "$line" >> "$SYSCTL_FILE"
				            echo "Added: $line"
					        else
							        echo "Already exists: $line"
								    fi
							    done
							     
							    sysctl -p
							     
							    # === 5. Update GRUB_CMDLINE_LINUX with transparent_hugepage=never ===
							    GRUB_FILE="/etc/default/grub"
							    if ! grep -q "transparent_hugepage=never" "$GRUB_FILE"; then
								        CURRENT_CMDLINE=$(grep "GRUB_CMDLINE_LINUX=" "$GRUB_FILE" | sed 's/GRUB_CMDLINE_LINUX="//; s/"$//')
									    NEW_CMDLINE="$CURRENT_CMDLINE transparent_hugepage=never"
									        sed -i "s|GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$NEW_CMDLINE\"|" "$GRUB_FILE"
										    echo "✅ Added 'transparent_hugepage=never' to GRUB_CMDLINE_LINUX"
									    else
										        echo "⚠️  'transparent_hugepage=never' already exists in GRUB_CMDLINE_LINUX"
							    fi
							     
							    # === 6. Disable Transparent Huge Pages (THP) ===
							    cat > /etc/systemd/system/disable-thp.service << 'EOF'
[Unit]
Description=Disable Transparent Huge Pages (THP)
 
[Service]
Type=simple
ExecStart=/bin/sh -c "echo 'never' > /sys/kernel/mm/transparent_hugepage/enabled && echo 'never' > /sys/kernel/mm/transparent_hugepage/defrag"
 
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl start disable-thp
systemctl enable disable-thp
 
# === 7. Start and Enable Chronyd ===
systemctl start chronyd
systemctl enable chronyd
 
# === 8. Configure NSCD (disable caching for passwd, group, netgroup) ===
NSCD_CONF="/etc/nscd.conf"

# Backup original if not already backed up
if [ ! -f "${NSCD_CONF}.original" ]; then
	    cp "$NSCD_CONF" "${NSCD_CONF}.original"
	        echo "✅ Backup created at ${NSCD_CONF}.original"
	else
		    echo "⚠️  Backup already exists. Skipping backup."
fi

# Function to set or replace enable-cache for a given service
set_cache() {
	    local SERVICE="$1"
	        local VALUE="$2"

		    if grep -qE "^\s*enable-cache\s+${SERVICE}\s+" "$NSCD_CONF"; then
			            # Line exists — replace whatever value it currently has
				            sed -i -E "s|^\s*enable-cache\s+${SERVICE}\s+.*|        enable-cache ${SERVICE} ${VALUE}|" "$NSCD_CONF"
					            echo "✅ Updated: enable-cache ${SERVICE} ${VALUE}"
						        else
								        # Line does not exist — append it
									        echo "        enable-cache ${SERVICE} ${VALUE}" >> "$NSCD_CONF"
										        echo "✅ Appended: enable-cache ${SERVICE} ${VALUE}"
											    fi
										    }

									    set_cache passwd   no
									    set_cache group    no
									    set_cache netgroup no
									     
									    # === 9. Start and Enable nscd ===
									    systemctl start nscd
									    systemctl enable nscd
									     
									    # === 10. Install Java 17 ===
									    yum install -y java-17-openjdk java-17-openjdk-devel
									    java -version
									     
									    # === 11. Set /tmp permissions ===
									    chmod 1777 /tmp
									     
									    # === 12. Set hostname to lowercase + .ocbcnisp.com (only if not already set) ===
									    CURRENT_HOSTNAME=$(hostname)
									    echo "Current hostname: $CURRENT_HOSTNAME"
									     
									    if echo "$CURRENT_HOSTNAME" | grep -qi "\.ocbcnisp\.com$"; then
										        echo "✅ Hostname already ends with .ocbcnisp.com. Skipping."
										else
											    NEW_HOSTNAME=$(echo "$CURRENT_HOSTNAME" | tr '[:upper:]' '[:lower:]').ocbcnisp.com
											        echo "New hostname: $NEW_HOSTNAME"
												    echo "$NEW_HOSTNAME" > /etc/hostname
												        echo "✅ Hostname set to: $NEW_HOSTNAME"
													    echo "✅ Current hostname after update:"
													        cat /etc/hostname
														    sed -i "s/^\(.*\) $CURRENT_HOSTNAME/\1 $NEW_HOSTNAME/" /etc/hosts
														        sed -i "s/^\(.*\) $CURRENT_HOSTNAME/\1 $NEW_HOSTNAME/" /etc/hosts
															    echo "✅ Updated /etc/hosts with new hostname"
															        systemctl restart NetworkManager
																    echo "✅ NetworkManager restarted"
									    fi
									     
									    # === 13. Copy x509 Certificates from Remote Host ===
									    echo "Copying x509 certificates from 10.104.6.124..."
									    scp -r admin@10.104.6.124:/opt/cloudera/security/x509 /home/admin/x509
									     
									    # === 14. Verify nscd configuration ===
									    echo "✅ Checking nscd configuration:"
									    grep -E "enable-cache\s+(passwd|group|netgroup)" /etc/nscd.conf
									     
									    # === 15. Optional: Verify krb5.conf ===
									    cat /etc/krb5.conf
									     
									    echo "✅ All steps completed successfully!"
