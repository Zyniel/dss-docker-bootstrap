# Runs inside the DSS container, started by check-license.sh, which sets up
# DSS's environment first.
#
# Asks the DSS backend whether it accepts its license, and prints the answer as
# "hasLicense=True valid=True expired=False".
#
# It connects the way DSS's own command line tool does (see
# dataiku/dsscli/__main__.py in the DSS installation): get_or_create_api_key
# reads a secret from the data directory and gets a temporary admin API key
# from the backend. That is internal to DSS, not a documented API, so it may
# change in a future DSS version; get_licensing_status is a public API call.
import os

import dataikuapi
from dataiku.dsscli.auth import get_or_create_api_key

backend_url = "http://127.0.0.1:%s" % os.environ["DKU_BACKEND_PORT"]
api_key = get_or_create_api_key(impersonate_user="")
client = dataikuapi.DSSClient(backend_url, api_key)

# The status also contains the license content (the licensee's name, email...):
# print only the three flags that say whether the license is usable.
status = client.get_licensing_status()
base = status.get("base") or {}
print("hasLicense=%s valid=%s expired=%s" % (base.get("hasLicense"), base.get("valid"), base.get("expired")))
