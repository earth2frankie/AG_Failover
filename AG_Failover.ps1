# Author : Wagner, Frank Werner <FrankWerner.Wagner@bwi.de>, BWI GmbH, 20.04.2022

function AG_Failover {

# initialize variables
$HealthCheckTimeout = 120 # number of seconds to check for healthy AG after failover
$ErrorActionPreference = 'Stop'
$dataset = New-Object System.Data.DataSet
$adapter = New-Object System.Data.SqlClient.SqlDataAdapter
$con = New-Object System.Data.SqlClient.SqlConnection
$cmd = New-Object System.Data.SqlClient.SqlCommand
$hostname = hostname
$logpath = $PSScriptRoot + '\log_failover.txt'
$xmlpath = $PSScriptRoot + '\groups.xml'
if (Test-Path $xmlpath)
    {
    Remove-Item $xmlpath
    }

# retrieve a list of all installed SQL Server Instances
Set-Content -Path $logpath -Value 'Retrieving Installed SQL Server Instances...'
$InstanceList = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server' -Name InstalledInstances
Add-Content -Path $logpath -Value $InstanceList

# iterate all instances, connect to each one and gather AG information
# -- for each AG that is primary in the current instance, get the ID, Name, Synch Health and 1 'synchron' secondary replica
# -- and save to table $groups
foreach ($instance in $InstanceList)
    {
    $fullinstance = $hostname + '\' + $instance
    $con.ConnectionString = 'Data Source=' + $fullinstance + ';Integrated Security=SSPI;Connection Timeout=1'
    $cmd.CommandText = $('
select ags.primary_replica, ag.name as ag_group, ag.group_id, ags.synchronization_health, min(ar.replica_server_name) as secondary_replica
from master.sys.availability_groups ag
inner join sys.dm_hadr_availability_group_states ags on ag.group_id = ags.group_id
inner join sys.dm_hadr_availability_replica_states ars on ags.group_id = ars.group_id
inner join master.sys.availability_replicas ar on ars.replica_id = ar.replica_id
where ags.primary_replica = @@SERVERNAME and ars.role = 2 and ar.availability_mode = 1
group by ags.primary_replica, ag.name, ag.group_id, ags.synchronization_health
 ')
    $cmd.Connection = $con
    $adapter.SelectCommand = $cmd
    Add-Content -Path $logpath -Value $('Connecting to ' + $fullinstance + ' and retrieving AG info...') -NoNewline
    try
        {
        $result = $adapter.Fill($dataset)
        Add-Content -Path $logpath -Value 'success.'
        }
    catch [System.Data.SqlClient.SqlException]
        {
        if ($($PSItem.Exception.Message) -like '*Login failed*')
            {
            Add-Content -Path $logpath -Value 'failed. Aborting operation.'
            Add-Content -Path $logpath -Value $(' - ' + $PSItem.Exception.Message)
            Exit 1 # ***** Login failed. Exit unsuccessfully.
            }
        Add-Content -Path $logpath -Value 'failed, skipping and continuing on.'
        Add-Content -Path $logpath -Value $(' - ' + $PSItem.Exception.Message)
        # skip and goto next
        }
    $con.Close()
    }
$groups = $dataset.Tables[0]
Add-Content -Path $logpath -Value $('Found ' + $groups.Rows.Count.ToString() + ' primary Availability Group(s) for failover...')
$groups | Format-Table -AutoSize | Out-File -FilePath $logpath -Encoding ascii -Append
if ($groups.Rows.Count -eq 0)
    {
    Add-Content -Path $logpath -Value 'Nothing to failover. Exiting successfully.'
    Exit 0 # ***** no AGs to failover. Exit successfully.
    }

# save table to XML file
Add-Content -Path $logpath -Value $('Saving table to XML file: ' + $xmlpath)
$writer = New-Object IO.StreamWriter $xmlpath
$groups.WriteXML($writer, [Data.XMLWriteMode]::WriteSchema)
$writer.Close()
$writer.Dispose()

# check if all AGs are healthy. Select statement returns 0 records if true.
$result = $groups.Select('synchronization_health < 2')
if ($result.Count -gt 0)
    {
    Add-Content -Path $logpath -Value $($result.Count.ToString() + ' Availability Group(s) are unhealthy. Aborting operation.')
    Exit 1 # ***** some AGs are unhealthy. Exit unsuccessfully.
    }
else
    {
    Add-Content -Path $logpath -Value 'All Availability Group(s) are healthy. Proceeding with failover.'
    }

# failover each AG and wait till healthy
foreach ($row in $groups.Rows)
    {
    $con.ConnectionString = 'Data Source=' + $row.Item('primary_replica') + ';Integrated Security=SSPI;Connection Timeout=1'
    $cmd.Connection = $con
    Add-Content -Path $logpath -Value $('Connecting to primary replica ' + $row.Item('primary_replica') + '...') -NoNewline
    try
        {
        $con.Open()
        Add-Content -Path $logpath -Value 'success.'
        }
    catch
        {
        Add-Content -Path $logpath -Value 'failed. Aborting operation.'
        Exit 1 # ***** unable to connect to primary replica. Exit unsuccessfully.
        }
    Add-Content -Path $logpath -Value $('Failing over Availability Group ' + $row.Item('ag_group') + '...') -NoNewline

    # do the failover
    $cmd.CommandText = $('
set nocount on
exec sp_configure ''show advanced options'', ''1''
reconfigure
exec sp_configure ''xp_cmdshell'', ''1''
reconfigure
exec xp_cmdshell ''sqlcmd -S ' + $row.Item('secondary_replica') + ' -Q ' + [char]34 + 'use master; alter availability group ' + $row.Item('ag_group') + ' failover' + [char]34 + ''', no_output
exec sp_configure ''xp_cmdshell'', ''0''
reconfigure
select count(*) from sys.dm_hadr_availability_group_states where group_id = ''' + $row.Item('group_id') + ''' and primary_replica = ''' + $row.Item('primary_replica') + '''
')
    [int]$result_failover = $cmd.ExecuteScalar()
 
    # wait till AG is healthy
    $cmd.CommandText = $('select count(*) from sys.dm_hadr_availability_group_states where group_id = ''' + $row.Item('group_id') + ''' and synchronization_health <> 2')
    for ($t=0;$t -lt $HealthCheckTimeout;$t++) # check the health status of the AG per Timeout value
        {
        [int]$result_healthy = $cmd.ExecuteScalar()
        if ($result_healthy -eq 0)
            {
            break # exit loop if AG is already healthy
            }
        Start-Sleep -Seconds 1
        }
    if (($result_failover -or $result_healthy) -gt 0)
        {
        Add-Content -Path $logpath -Value $('failed. Aborting operation. ' + $resultconnect)
        Exit 1 # ***** failover failed or AG not returning to healthy after failover. Exit Unsuccessfully.
        }
    Add-Content -Path $logpath -Value $('success. (' + $t + ' seconds)')
    $con.Close()
    }
Exit 0 # ***** Exit successfully
}
AG_Failover