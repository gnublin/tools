#!/usr/bin/env ruby

require 'socket'
require 'getoptlong'
require 'pp'
require 'csv'
require 'net/http'
require 'net/ssh'
require 'uri'

=begin 
    Variable global declaration
=end
@instancePath = '/var/run/haproxy'
@sshUserName = `logname`.strip
@myHaCmd = "/usr/local/bin/hasocket.rb"
@myArg = ARGV
@myAllArg = ''
@haGroup = 'haproxy'

@myArg.each do |my|
    next if my == '--remote'
    next if my == '-r'
    @myAllArg = @myAllArg + my + ' '
end

opts = GetoptLong.new(
    ['--server', '-s', GetoptLong::REQUIRED_ARGUMENT],
    ['--backend', '-b', GetoptLong::REQUIRED_ARGUMENT],
    ['--instance', '-i', GetoptLong::REQUIRED_ARGUMENT],
    ['--user', '-u', GetoptLong::REQUIRED_ARGUMENT],
    ['--help', '-h', GetoptLong::NO_ARGUMENT],
    ['--enable', '-e', GetoptLong::NO_ARGUMENT],
    ['--disable', '-d', GetoptLong::NO_ARGUMENT],
    ['--remote', '-r', GetoptLong::NO_ARGUMENT],
    ['--prod', '-p', GetoptLong::NO_ARGUMENT],
    ['--qa', '-q', GetoptLong::NO_ARGUMENT],
    ['--stat', '-t', GetoptLong::NO_ARGUMENT]
)

def help()
    puts ''
    puts "   Usage #{$0} : "
    puts '\t--instance\t| -i |\t Name of haproxy instance'
    puts '\t--server\t| -s |\t Name of server you want to disable'
    puts '\t--backend\t| -b |\t From backend you want server disabled. You can user multi-backend like \"back1 back2\". Default all backend'
    puts '\t--enable\t| -e |\t Enable server'
    puts '\t--disable\t| -d |\t Disable server'
    puts '\t--help\t\t| -h |\t This help'
end

@lbList = { 
    "prod" => ["lbprod-01", "lbprod-02"], 
    "qa" => ["lbqa-01"],
    }

opts.each do |opt, arg|

    case opt 
        when '--help'
            help()
            exit
        when '--server'
            @serverName = arg
        when '--backend'
            @backendName = arg
        when '--instance'
            @instanceName = arg
        when '--enable'
            @toStatus='enable'
            @notStatus='UP'
        when '--disable'
            @toStatus='disable'
            @notStatus='MAINT'
        when '--prod'
            if @env 
                puts "You should choose one only environement"
                exit
            end
                @env = 'prod'
        when '--qa'
            if @env
                puts "You should choose one only environement"
                exit
            end
            @env = 'qa'
        when '--remote'
            @remote = true
        when '--stat'
            @stat = true
        when '--user'
            @sshUserName = arg
    end
end

if @stat != true

    if ! @toStatus
        puts 'You should choose between enable or diable option'
        help()
        exit
    end
    
    if ! @serverName
        puts 'You should choose a server to disable'
        help()
        exit
    end
    
    
    if ! @backendName
        @backendName = 'all'
    end
    
    @backendName = @backendName.split(' ')
end

if ! @env 
    puts 'You should to choose en environement --prod or --qa'
    exit
else
    @lbList = @lbList[@env]
end
    

if ! @instanceName
    puts 'You should choose an haproxy instance'
    help()
    exit
else
    @instanceFile = "#{@instancePath}-#{@instanceName}.stat"
end

def checkHaproxyGroup()

    if @remote === true
        @lbList.each do |lbSRV|
            Net::SSH.start(lbSRV, @sshUserName) do|ssh|
                result = ssh.exec!('groups')
                result = result.split(" ")
                result1 = ssh.exec!("test -x #{@myHaCmd} ; echo $?")
                @result1 = result1.to_i
                @haproxyRight = result.include? "#{@haGroup}"
            end
        end
    else
        result = `groups`
        result = result.split(" ")
        result1 = `test -x #{@myHaCmd} ; echo $?`
        @result1 = result1.to_i
        @haproxyRight = result.include? "#{@haGroup}"
    end

    if @haproxyRight != true
        puts "You don't have permission to execute this script"
        exit
    end
    if @result1 != 0
        puts "#{@myHaCmd} is not present on this server"
        exit
    end
end


def checkHaproxyBackend()

    socket = UNIXSocket.new("#{@instanceFile}")
    socket.puts('show stat')
    httpBody = ''

    while(line = socket.gets) do
        httpBody = httpBody + line
    end

    listBackend = Array.new
    
    CSV.parse(httpBody) do |row|
        if (row[1] == @serverName) and not (row[17] == @notStatus)
            listBackend << row[0]
        end
        if ( @backendName.first == 'all' ) and (row[1] == 'BACKEND')
            @backendName << row[0]
        end
    end
    
    toListBackend = listBackend & @backendName
    return toListBackend
end

def checkHaStat(lbSRV)
    @haresBody = ''
    if @remote === true
        Net::SSH.start(lbSRV, @sshUserName) do|ssh|
            @haresBody = ssh.exec!("#{@myHaCmd} --stat --instance #{@instanceName} --#{@env}")
        end
    else
        socket = UNIXSocket.new("#{@instanceFile}")
        socket.puts("show stat")
        while(line = socket.gets) do
            @haresBody = @haresBody + line
        end
    end

    return @haresBody
end

def doSocket(lbSRV, toListBackend)
    
    toListBackend.each do |backend|
        if @remote === true
            Net::SSH.start(lbSRV, @sshUserName) do|ssh|
               hares = ssh.exec!("#{@myHaCmd} #{@myAllArg} --backend #{backend} ; echo -n $?")
               hares = hares.gsub(/\n/,"")
               @haresult = hares.split("").last
            end
        else
            begin
                socket = UNIXSocket.new("#{@instanceFile}")
                socket.puts("#{@toStatus} server #{backend}/#{@serverName}")
                @haresult = "0"
            rescue
                @haresult = "1"
            end
        end

        if "#{@haresult}" == "0"  
           puts "Server #{@serverName} is now #{@toStatus} for #{backend} on #{lbSRV}" 
        else
            puts "Error occurred for #{@toStatus} for #{@serverName} with #{backend} on #{lbSRV}"
            exit
        end
   end
end

def csvHaParser (csvToParse)
    listBackend = Array.new
    CSV.parse(csvToParse) do |row|
        if (row[1] == @serverName) and not (row[17] == @notStatus)
            listBackend << row[0]
        end
        if ( @backendName.first == 'all' ) and (row[1] == 'BACKEND')
            @backendName << row[0]
        end
    end
    
    toListBackend = listBackend & @backendName
    return toListBackend
end


checkHaproxyGroup()
@lbList.each do |lbSRV|
    stats = checkHaStat(lbSRV)
    if @stat === true
        puts stats
       exit 
    else 
        toListBackend = csvHaParser(stats)
        if toListBackend.empty? === true
            puts "#{@serverName} is not in #{@notStatus} mode in #{@backendName[0]} backend on #{lbSRV}"
            exit
        else
            doSocket(lbSRV, toListBackend)
        end
        sleep 2
    end
end
