#!/usr/bin/env php
<?php
/**
 * scripts-tools Cacti customer provisioning for Debian 13's Cacti 1.2.30.
 * Invocation only through root-owned cacti_account.sh.
 * Uses Cacti's own database abstraction + official add_graphs.php to create graphs.
 */
declare(strict_types=1);

if (PHP_SAPI !== 'cli') { fwrite(STDERR, "CLI only\n"); exit(1); }
if (function_exists('posix_geteuid') && posix_geteuid() !== 0) { fwrite(STDERR, "Run as root\n"); exit(1); }
$cliBootstrap = '/usr/share/cacti/site/include/cli_check.php';
$graphCli = '/usr/share/cacti/cli/add_graphs.php';
if (!is_file($cliBootstrap) || !is_file($graphCli)) {
    fwrite(STDERR, "Debian Cacti installation not found (expected /usr/share/cacti).\n"); exit(1);
}
require $cliBootstrap;
if (($config['poller_id'] ?? 1) > 1) { db_switch_remote_to_main(); }

function stop(string $message): never { fwrite(STDERR, "ERROR: $message\n"); exit(1); }
function qcell(string $sql, array $values = []): mixed { return db_fetch_cell_prepared($sql, $values); }
function qrows(string $sql, array $values = []): array { return db_fetch_assoc_prepared($sql, $values) ?: []; }
function execsql(string $sql, array $values = []): void {
    $result = db_execute_prepared($sql, $values);
    if ($result === false) { throw new RuntimeException('Database write failed'); }
}
function valid_user(string $username): void {
    if (!preg_match('/^[a-z][a-z0-9_.-]{2,49}$/D', $username) || in_array($username, ['admin', 'guest'], true)) {
        stop('Username must be 3-50 chars, start with a letter, use a-z, digits, _ . -, and not be admin/guest');
    }
}
function validate_selector(string $selector): array {
    $parts = explode(':', $selector, 3);
    if (count($parts) === 2) { [$host, $value] = $parts; $field = 'ifName'; }
    elseif (count($parts) === 3) { [$host, $field, $value] = $parts; }
    else { stop("Invalid selector '$selector'; expected DEVICE_ID:ifName or DEVICE_ID:field:value"); }
    if (!ctype_digit($host) || (int)$host < 1) { stop("Invalid device ID in '$selector'"); }
    if (!in_array($field, ['ifName', 'ifDescr', 'ifAlias', 'ifIndex'], true)) {
        stop("Invalid selector field '$field' (ifName, ifDescr, ifAlias, ifIndex only)");
    }
    if ($value === '' || strlen($value) > 255) { stop('Interface value must be 1-255 characters'); }
    if ($field === 'ifIndex' && (!ctype_digit($value) || (int)$value < 1)) {
        stop('ifIndex must be a positive integer');
    }
    return [(int)$host, $field, $value];
}
function resolve_interfaces(array $selectors): array {
    $queryId = qcell("SELECT id FROM snmp_query WHERE name = 'SNMP - Interface Statistics' LIMIT 1");
    if (!$queryId) { stop('Missing SNMP - Interface Statistics data query; import Cacti default templates'); }
    $queryId = (int)$queryId;
    $types = qrows("SELECT sqg.id AS query_type_id, sqg.graph_template_id
       FROM snmp_query_graph AS sqg
       WHERE sqg.snmp_query_id = ? AND sqg.name = 'In/Out Bits (64-bit Counters)'", [$queryId]);
    if (count($types) !== 1) {
        stop('64-bit In/Out Bits query type missing/ambiguous. Verify template in Cacti > Data Queries');
    }
    $queryType = (int)$types[0]['query_type_id'];
    $graphTemplateId = (int)$types[0]['graph_template_id'];
    $selected = [];
    foreach ($selectors as $selector) {
        [$host, $field, $value] = validate_selector($selector);
        $device = qrows('SELECT id, description FROM host WHERE id = ? AND disabled = ?', [$host, '']);
        // Some Cacti packages use disabled '' and others NULL; reject only missing device here.
        if (!$device) { $device = qrows('SELECT id, description FROM host WHERE id = ?', [$host]); }
        if (!$device) { stop("No Cacti device with ID $host"); }
        $attached = qcell('SELECT COUNT(*) FROM host_snmp_query WHERE host_id = ? AND snmp_query_id = ?', [$host, $queryId]);
        if ((int)$attached === 0) { stop("Device $host lacks the interface data query; attach it first"); }
        $matches = qrows('SELECT DISTINCT snmp_index FROM host_snmp_cache WHERE host_id=? AND snmp_query_id=? AND field_name=? AND field_value=? AND present=1',
            [$host, $queryId, $field, $value]);
        if (count($matches) !== 1) {
            stop("'$selector' matched " . count($matches) . " interfaces; refresh Cacti SNMP cache or use exact ifIndex");
        }
        $index = (string)$matches[0]['snmp_index'];
        if ($index === '' || !preg_match('/^[0-9.]+$/D', $index)) { stop('Unsafe/malformed SNMP index returned by Cacti cache'); }
        $selected[$host . ':' . $index] = [
            'host' => $host, 'index' => $index, 'query_id' => $queryId,
            'query_type' => $queryType, 'graph_template_id' => $graphTemplateId,
            'selector' => $selector, 'device' => $device[0]['description'],
        ];
    }
    return array_values($selected);
}
function get_graph_id(array $s): int {
    $rows = qrows('SELECT id FROM graph_local WHERE host_id=? AND snmp_query_id=? AND snmp_query_graph_id=? AND snmp_index=?',
        [$s['host'], $s['query_id'], $s['query_type'], $s['index']]);
    if (count($rows) > 1) { stop("Duplicate graph identities for {$s['selector']} (repair in Cacti)"); }
    return count($rows) ? (int)$rows[0]['id'] : 0;
}
function create_graph_if_missing(array $s): int {
    $id = get_graph_id($s);
    if ($id) { return $id; }
    $cmd = [PHP_BINARY, '/usr/share/cacti/cli/add_graphs.php',
        '--host-id=' . $s['host'], '--graph-type=ds',
        '--graph-template-id=' . $s['graph_template_id'],
        '--snmp-query-id=' . $s['query_id'], '--snmp-query-type-id=' . $s['query_type'],
        '--snmp-field=ifIndex', '--snmp-value=' . $s['index']];
    $pipes = [];
    $p = proc_open($cmd, [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
    if (!is_resource($p)) { stop('Could not execute official Cacti graph CLI'); }
    fclose($pipes[0]);
    $out = stream_get_contents($pipes[1]); fclose($pipes[1]);
    $err = stream_get_contents($pipes[2]); fclose($pipes[2]);
    $exit = proc_close($p);
    if ($exit !== 0) { stop("Cacti graph creation failed for {$s['selector']}: " . trim($out . ' ' . $err)); }
    $id = get_graph_id($s);
    if (!$id) { stop("Graph CLI exited successfully but no corresponding indexed graph found: {$s['selector']}"); }
    return $id;
}
function customer_id(string $username): int {
    return (int)qcell('SELECT id FROM user_auth WHERE username=? AND realm=0', [$username]);
}
function is_managed(string $username): bool {
    return (int)qcell("SELECT COUNT(*) FROM user_auth WHERE username=? AND realm=0 AND full_name=?",
        [$username, 'Customer portal - ' . $username]) === 1;
}

function audit(string $username, int $id, bool $verbose = true): bool {
    $info = qrows('SELECT enabled, policy_graphs,policy_trees,policy_hosts,policy_graph_templates FROM user_auth WHERE id=?', [$id]);
    if (!$info) { stop('User no longer exists'); }
    $i = $info[0];
    $problems = [];
    foreach (['policy_graphs','policy_trees','policy_hosts','policy_graph_templates'] as $key) {
        if ((int)$i[$key] !== 2) { $problems[] = "$key is not deny-by-default"; }
    }
    $groups = (int)qcell('SELECT COUNT(*) FROM user_auth_group_members WHERE user_id=?', [$id]);
    if ($groups) { $problems[] = 'group membership exists'; }
    $otherPerms = (int)qcell('SELECT COUNT(*) FROM user_auth_perms WHERE user_id=? AND type<>1', [$id]);
    if ($otherPerms) { $problems[] = 'device/tree/template permissions exist'; }
    $realms = qrows('SELECT realm_id FROM user_auth_realm WHERE user_id=?', [$id]);
    $realmIds = array_map(static fn($r) => (int)$r['realm_id'], $realms);
    sort($realmIds);
    if ($i['enabled'] === 'on' && $realmIds !== [7]) { $problems[] = 'unexpected realm permissions: ' . implode(',', $realmIds); }
    if ($verbose) {
        echo "$username | enabled={$i['enabled']} | groups=$groups | realms=" . implode(',', $realmIds) . PHP_EOL;
        $graphs = qrows('SELECT p.item_id, h.description AS device, gl.snmp_index FROM user_auth_perms AS p LEFT JOIN graph_local AS gl ON gl.id=p.item_id LEFT JOIN host AS h ON h.id=gl.host_id WHERE p.user_id=? AND p.type=1 ORDER BY p.item_id', [$id]);
        foreach ($graphs as $g) { echo "  graph={$g['item_id']} device=" . ($g['device'] ?? '?') . " index=" . ($g['snmp_index'] ?? '?') . PHP_EOL; }
        echo $problems ? 'AUDIT FAIL: ' . implode('; ', $problems) . PHP_EOL : "AUDIT OK: user policies are least-privilege\n";
    }
    return !$problems;
}
$action = $argv[1] ?? 'help';
try {
    switch ($action) {
        case 'devices':
            foreach (qrows('SELECT id,description,hostname FROM host ORDER BY id') as $r) {
                echo "{$r['id']}\t{$r['description']}\t{$r['hostname']}\n";
            }
            break;
        case 'interfaces':
            $host = $argv[2] ?? '';
            if (!ctype_digit($host) || (int)$host < 1) { stop('Usage: interfaces DEVICE_ID'); }
            $queryId = qcell("SELECT id FROM snmp_query WHERE name='SNMP - Interface Statistics' LIMIT 1");
            foreach (qrows("SELECT snmp_index,
              MAX(CASE WHEN field_name='ifName' THEN field_value ELSE NULL END) AS ifName,
              MAX(CASE WHEN field_name='ifDescr' THEN field_value ELSE NULL END) AS ifDescr,
              MAX(CASE WHEN field_name='ifAlias' THEN field_value ELSE NULL END) AS ifAlias
              FROM host_snmp_cache WHERE host_id=? AND snmp_query_id=? AND present=1
              GROUP BY snmp_index ORDER BY CAST(snmp_index AS UNSIGNED)", [(int)$host, (int)$queryId]) as $r) {
                printf("%-12s %-24s %-28s %s\n", $r['snmp_index'], $r['ifName'] ?? '', $r['ifDescr'] ?? '', $r['ifAlias'] ?? '');
            }
            break;
        case 'add':
            $username = $argv[2] ?? '';
            valid_user($username);
            if (count($argv) < 5) { stop('Usage: add USERNAME --stdin-password DEVICE_ID:ifName:value [more selectors]'); }
            if ($argv[3] !== '--stdin-password') { stop('Password must be provided via --stdin-password to prevent process-list exposure'); }
            if (customer_id($username)) { stop("Account '$username' already exists (including disabled accounts)"); }
            $targets = resolve_interfaces(array_slice($argv, 4)); // validate all BEFORE creating graphs/user
            $pw = rtrim((string)fgets(STDIN), "\r\n");
            if (strlen($pw) < 12 || strlen($pw) > 128) { stop('Password must be 12-128 bytes'); }
            $pwHash = password_hash($pw, PASSWORD_DEFAULT);
            unset($pw);
            $graphIds = [];
            foreach ($targets as $t) {
                $graphId = create_graph_if_missing($t);
                $otherTenants = qrows("SELECT u.username FROM user_auth_perms p JOIN user_auth u ON u.id=p.user_id WHERE p.type=1 AND p.item_id=? AND u.enabled='on' AND u.full_name LIKE 'Customer portal - %'", [$graphId]);
                if ($otherTenants) { stop("Graph $graphId already granted to customer " . $otherTenants[0]['username'] . '; refusing cross-customer assignment'); }
                $graphIds[$graphId] = true;
                echo "Graph ready: ID=$graphId {$t['device']} / {$t['selector']}\n";
            }
            if (!$graphIds) { stop('No graphs to grant'); }
            execsql('START TRANSACTION');
            try {
                execsql("INSERT INTO user_auth (username,password,realm,full_name,must_change_password,password_change,show_tree,show_list,show_preview,login_opts,policy_graphs,policy_trees,policy_hosts,policy_graph_templates,enabled,lastchange) VALUES (?,?,0,?,'','on','','on','on',3,2,2,2,2,'on',?)",
                    [$username, $pwHash, 'Customer portal - ' . $username, time()]);
                $id = customer_id($username);
                if (!$id) { throw new RuntimeException('User insert returned no ID'); }
                execsql('INSERT INTO user_auth_realm (realm_id,user_id) VALUES (7,?)', [$id]);
                foreach (array_keys($graphIds) as $graphId) {
                    execsql('INSERT INTO user_auth_perms (user_id,item_id,type) VALUES (?,?,1)', [$id, $graphId]);
                }
                execsql('COMMIT');
            } catch (Throwable $e) { db_execute('ROLLBACK'); throw $e; }
            echo "Created '$username' with " . count($graphIds) . " explicitly permitted graphs.\n";
            if (!audit($username, $id)) { stop('SECURITY AUDIT FAILED; disable account immediately'); }
            break;
        case 'remove':
            $username = $argv[2] ?? ''; valid_user($username);
            $id = customer_id($username);
            if (!$id || !is_managed($username)) { stop("No such managed customer account '$username'"); }
            execsql('START TRANSACTION');
            try {
                execsql("UPDATE user_auth SET enabled='',locked='on' WHERE id=?", [$id]);
                execsql('DELETE FROM user_auth_perms WHERE user_id=?', [$id]);
                execsql('DELETE FROM user_auth_realm WHERE user_id=?', [$id]);
                execsql('DELETE FROM user_auth_group_members WHERE user_id=?', [$id]);
                execsql('DELETE FROM user_auth_cache WHERE user_id=?', [$id]);
                execsql('DELETE FROM user_auth_row_cache WHERE user_id=?', [$id]);
                execsql('COMMIT');
            } catch (Throwable $e) { db_execute('ROLLBACK'); throw $e; }
            echo "Disabled '$username', revoked all permissions and remember-me tokens; retained graph/RRD history.\n";
            echo "Note: active Cacti browser sessions may remain valid until session expiry; invalidate sessions at PHP/session layer for immediate revocation.\n";
            break;
        case 'list':
            foreach (qrows("SELECT u.id,u.username,u.enabled,COUNT(p.item_id) AS graphs FROM user_auth u LEFT JOIN user_auth_perms p ON p.user_id=u.id AND p.type=1 WHERE u.realm=0 AND u.full_name LIKE 'Customer portal - %' GROUP BY u.id ORDER BY u.username") as $r) {
                echo "{$r['username']}\t{$r['enabled']}\tgraphs={$r['graphs']}\n";
            }
            break;
        case 'audit-all':
            $bad = false;
            $users = qrows("SELECT id,username FROM user_auth WHERE full_name LIKE 'Customer portal - %' AND realm=0 ORDER BY username");
            foreach ($users as $u) {
                if (!audit($u['username'], (int)$u['id'])) { $bad = true; }
            }
            $shared = qrows("SELECT p.item_id, COUNT(DISTINCT p.user_id) AS n FROM user_auth_perms p JOIN user_auth u ON u.id=p.user_id WHERE p.type=1 AND u.enabled='on' AND u.full_name LIKE 'Customer portal - %' GROUP BY p.item_id HAVING COUNT(DISTINCT p.user_id)>1");
            foreach ($shared as $s) { echo "AUDIT FAIL: graph {$s['item_id']} shared among {$s['n']} active customers\n"; $bad = true; }
            if (!$bad) { echo "All managed customer ACLs passed audit.\n"; }
            exit($bad ? 2 : 0);
        case 'show':
        case 'audit':
            $username = $argv[2] ?? ''; valid_user($username);
            $id = customer_id($username);
            if (!$id || !is_managed($username)) { stop('Managed customer account not found'); }
            $ok = audit($username, $id);
            if (!$ok) { exit(2); }
            break;
        case 'lockdown':
            // Intended for NEW installations; disabling guest is an intentional global change.
            execsql("UPDATE user_auth SET enabled='' WHERE username='guest'");
            set_config_option('guest_user', '0');
            echo "Disabled anonymous guest account; set guest_user=0.\n";
            break;
        case 'reset-admin':
            $pw = rtrim((string)fgets(STDIN), "\r\n");
            if (strlen($pw) < 12 || strlen($pw) > 128) { stop('Password must be 12-128 bytes'); }
            execsql("UPDATE user_auth SET password=?,must_change_password='',enabled='on',locked='',failed_attempts=0,lastchange=? WHERE username='admin' AND realm=0", [password_hash($pw,PASSWORD_DEFAULT), time()]);
            echo "Admin password updated using PASSWORD_DEFAULT hash.\n";
            break;
        default:
            echo "Usage: cacti_account.sh add USER PASSWORD SELECTOR [SELECTOR ...]\n";
            echo "       cacti_account.sh remove USER | list | show USER | audit USER | audit-all\n";
            echo "       cacti_account.sh devices | interfaces DEVICE_ID | reset-admin\n";
            echo "Selectors: DEVICE_ID:ifName:value or DEVICE_ID:ifIndex:N or DEVICE_ID:ifAlias:value\n";
            break;
    }
} catch (Throwable $e) {
    stop($e->getMessage());
}
