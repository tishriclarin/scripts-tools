import unittest
from zte_cli import parse_types, parse_vlan_profiles, parse_traffic_profiles, parse_pon_descriptions, parse_nids, resolve_cached, CliError

CONFIG = '''
vlan-profile VLAN50
!
vlan-profile VLAN51
!
interface gpon-olt_1/3/1
 description "::VLAN-PROFILE:VLAN51"
 onu 1 type GENERIC-HGU sn VSOL00956136
 onu 2 type GENERIC_HGU sn VSOL00E2033A
!
interface gpon-onu_1/3/1:1
 traffic-profile DATA-1G-DOWN vport 1 direction ingress
 traffic-profile DATA-1G-UP vport 1 direction egress
!
'''
class CacheTests(unittest.TestCase):
    def test_types_order(self): self.assertEqual(parse_types(CONFIG), ['GENERIC-HGU','GENERIC_HGU'])
    def test_vlan_order(self): self.assertEqual(parse_vlan_profiles(CONFIG), ['VLAN50','VLAN51'])
    def test_traffic(self): self.assertEqual(parse_traffic_profiles(CONFIG), {'ingress':['DATA-1G-DOWN'],'egress':['DATA-1G-UP']})
    def test_nids(self): self.assertEqual(parse_nids(parse_pon_descriptions(CONFIG)['1/3/1'])['VLAN-PROFILE'], 'VLAN51')
    def test_fallback(self): self.assertEqual(resolve_cached(None, parse_vlan_profiles(CONFIG), 'VLAN-PROFILE'), ('VLAN50','CACHE-FIRST'))
    def test_explicit_missing(self):
        with self.assertRaises(CliError): resolve_cached('MISSING',parse_vlan_profiles(CONFIG),'VLAN-PROFILE')
    def test_hyphen(self): self.assertEqual(parse_nids('::VLAN-PROFILE:VLAN50_TRAFFIC-INGRESS:DATA-1G-DOWN')['TRAFFIC-INGRESS'],'DATA-1G-DOWN')
if __name__ == '__main__': unittest.main()