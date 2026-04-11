# Export on source system
pnputil /export-driver * c:\drivers

# Import on target system
pnputil /add-driver "c:\drivers\*.inf" /subdirs /install