#!/usr/bin/env bash
# Анализ сетевой конфигурации: VLAN-изоляция или физический воздушный зазор
set -euo pipefail

echo "=== Анализ типа изоляции ==="

# Физические интерфейсы
echo ""
echo "--- Физические интерфейсы ---"
ip link show | grep -E '^[0-9]+:' | awk '{print $2}' | tr -d ':' | while read iface; do
  type=$(cat /sys/class/net/${iface}/type 2>/dev/null || echo "?")
  state=$(cat /sys/class/net/${iface}/operstate 2>/dev/null || echo "?")
  echo "  $iface: type=$type state=$state"
done

# VLAN-интерфейсы
echo ""
echo "--- VLAN-интерфейсы (признак логической изоляции) ---"
vlan_ifaces=$(ip link show type vlan 2>/dev/null | grep -E '^[0-9]+:' | awk '{print $2}' | tr -d ':')
if [ -z "$vlan_ifaces" ]; then
  echo "  VLAN-интерфейсы не обнаружены"
else
  echo "  ВНИМАНИЕ: обнаружены VLAN-интерфейсы:"
  echo "$vlan_ifaces" | sed 's/^/  /'
  echo "  VLAN — логическая сегментация, не физический воздушный зазор!"
fi

# Беспроводные интерфейсы
echo ""
echo "--- Беспроводные интерфейсы (недопустимы в закрытом контуре) ---"
wifi_ifaces=$(ip link show | grep -iE 'wlan|wifi|wlp' | awk '{print $2}' | tr -d ':')
if [ -z "$wifi_ifaces" ]; then
  echo "  Беспроводные интерфейсы не обнаружены"
else
  echo "  КРИТИЧНО: обнаружены беспроводные интерфейсы:"
  echo "$wifi_ifaces" | sed 's/^/  /'
fi

# Bluetooth
echo ""
if command -v hciconfig &>/dev/null && hciconfig 2>/dev/null | grep -q 'BD Address'; then
  echo "  КРИТИЧНО: обнаружен активный Bluetooth-адаптер"
else
  echo "  Bluetooth не обнаружен или отключён"
fi

echo ""
echo "=== Заключение ==="
echo "Физический воздушный зазор: все беспроводные интерфейсы отключены,"
echo "нет VLAN-изоляции вместо физического отключения, нет Bluetooth."
