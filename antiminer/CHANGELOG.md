version 2.0 (beta)
- initial version (improved / re-writted previous v.1)

version 2.0-b1 (beta)
- changed getting of billing group name to billing group name + billing group type both via API and DB
- changed body for some reports
- improved identification of user registration IP via API
- improved apiChangeMinerStatus function workflow
- fixed identification logic of process signature
- fixed report of mining pool domain list if domains more than one

version 2.0-b2 (beta)
- fixed include config order

version 2.0-b3 (beta)
- improved regexp for IPs to avoid false-positive reports
- improved initialization logic of searchByTimeConsumeProcInTop function

version 2.0-b4 (beta)
- avoided of mysql warning if not mariaDB installed on the server
- optimized processing of trusted excludes
- improved report to process only uniq pid to decrease false-positive reports

version 2.0-b5 (beta)
- added alternative report sender
- added ability to exclude trusted by email or billing group

version 2.0-b6 (beta)
- improved report about new pool for maintainer
- fixed alternative report sender to support multiple recipients

version 2.0-b7 (beta)
- fixed error value too great for base for uuid named CTs
- improved error logger

version 2.0-b8 (beta)
- changed full domain to short domain because some domains are blocked by antispam

version 2.0-b9 (beta)
- some smal improvements and optimizations
- changed variables order in config file

version 2.0-b10 (beta)
- added more interactivity to server scripts (support request)
- added https://minerstat.com/mining-pool-whitelist.txt to server scripts as an additional source of miner pools
- added id of signature to antiminer.miner_details the user was deactivated with (support request)

version 2.0-b11 (beta)
- increased a signature depth twice to avoid false-positive detection in context of the signature. Still the same depth (2048 byte) in maintainer report not to overload a mail
- added signature id to log if user's process signature matches with known one
- improved list of domain in a report if there is more than one domain per IP in order not to overload the report
- cleaned up old pool domain list from our DB which was not maintened. The main list is https://minerstat.com/mining-pool-whitelist.txt which updates daily. This should help to avoid some more false-positive detection in a context of miner pools
- added new variable to process billing groups in context of deactivation, suspention etc. A whole trial group type is still hardcoded so used by default and can't be changed but new billing group can be added in config (e.i. testrunner_beta, testrunner_post etc.)
- added new miner min probability threshold variable which allows process user (deactivate, destroy etc.) with predefined miner probability (99 by default). Previously only users with 99% miner probability were processed 
- added new variable for reports which allows not to send report if miner probability less than the predefined value
- added new variable to interrupt API calls within the predefined value as a replacement of a hardcode

version 2.0-b12 (beta)
- added a threat name to full miner process name for report and log in case if a threat is found just by clamav own virus-base
- took out apiChangeMinerStatus options to config
- speeded up script execution

version 2.0-b13 (beta)
- fixed grep options which stop working in some cases

version 2.0-b14 (beta)
- optimized search by minerpool
- changed default MINER_PROB_REPORT_MIN to 60% to minimize a chance of false-positive alerts. 50% setup previously had rather annoying point than detection of real miner (but chance to miss some miners is increased a bit though). At the same time, maintainer will be getting new pool/signature reports so such miners will be under control

version 2.0-b15 (beta)
- fixed "send from" for cases if hostname consists only shortname
- trimmed a possible whitespaces for full process name

version 2.0-b16 (beta)
- trimmed a possible whitespaces for short process name
- fixed an interruption of searchOutput function if short process name has different kind of brackets

version 2.0-b17 (beta)
- improved getting of pool IPs in case of geoDNS (server script)
- fixed downloading of recources. Resources download only if they were changed on server
- fixed the buggy search by miner IP, which could lead to prolonged script execution

version 2.0-b18 (beta)
- improved script to check top current 3 CPU consumers and top 3 CPU time consumers overall processes time to increase probibility to catch the renamed process without known pool IP

version 2.0-b19 (beta)
- changed miner probability if signature and pool are known and miner was detected by searchByTimeConsumeProcInTop function
- avoid duplication if miner pool is different in detect report
- possibility to leave comment in ip pool list of server script

version 2.0-b20 (beta)
- set miner IP to null if empty

version 2.0-b21 (beta)
- added --max-filesize=500M for clamscan to see files larger than 30M

version 2.0-b22 (beta)
- removed getPlatformVersion function which was implemented for old platform version
- fix output of api functions if response contains asterisk which prints all files and can affect getting actual data from API

version 2.0-b23 (beta)
- changed link to the knowledgebase because of rebranding
- changed email addresses for reports
