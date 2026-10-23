#!/bin/bash
# Build the Maven-style Java scenario used to compare unit-test gates.
# usage: mkjava.sh <git-repo-dir> [stage:yes|no]
# Result (uncommitted edits on top of a "java baseline" commit):
#   OrderService.java        modified + OrderServiceTest.java (with @Test) modified   -> must PASS
#   OrderController.java     modified, NO test                                         -> must FAIL
#   UserService.java         interface "extends BaseService<String>" modified          -> must be SKIPPED
#   PayServiceImpl.java      modified + PayServiceTest.java (Impl stripped) with @Test -> must PASS
#   StockService.java        modified + StockServiceTest.java WITHOUT @Test (shell)    -> must FAIL
#   AuditService.java        deleted                                                   -> must be IGNORED
set -e
D=$1; STAGE=${2:-no}; cd "$D"
J=src/main/java/com/acme; T=src/test/java/com/acme; mkdir -p $J $T
cat > $J/OrderService.java <<'X'
package com.acme;
public class OrderService { public Long create(String no) { return 1L; } }
X
cat > $J/OrderController.java <<'X'
package com.acme;
public class OrderController { public Long post(String no) { return 1L; } }
X
cat > $J/UserService.java <<'X'
package com.acme;
public interface UserService extends BaseService<String> { String name(long id); }
X
cat > $J/PayServiceImpl.java <<'X'
package com.acme;
public class PayServiceImpl implements PayService { public void pay() {} }
X
cat > $J/StockService.java <<'X'
package com.acme;
public class StockService { public int left() { return 0; } }
X
cat > $J/AuditService.java <<'X'
package com.acme;
public class AuditService { public void log() {} }
X
cat > $T/OrderServiceTest.java <<'X'
package com.acme;
import org.junit.jupiter.api.Test;
class OrderServiceTest { @Test void create_ok() {} }
X
cat > $T/PayServiceTest.java <<'X'
package com.acme;
import org.junit.jupiter.api.Test;
class PayServiceTest { @Test void pay_ok() {} }
X
cat > $T/StockServiceTest.java <<'X'
package com.acme;
class StockServiceTest { void helperOnly() {} }
X
git add -A >/dev/null 2>&1; git -c user.email=a@b -c user.name=t commit -qm "java baseline" --no-verify
for f in OrderService OrderController UserService PayServiceImpl StockService; do echo "// edit" >> $J/$f.java; done
echo "// edit" >> $T/OrderServiceTest.java; echo "// edit" >> $T/PayServiceTest.java; echo "// edit" >> $T/StockServiceTest.java
git rm -q $J/AuditService.java
[ "$STAGE" = "yes" ] && git add -A >/dev/null 2>&1
echo "scenario ready in $D"
