#!/usr/bin/env ruby

require 'aws-sdk'
require 'getoptlong'
require 'pp'


@vpcID="vpc-XXXX"

if ARGV.length == 0
    puts "Missing dir argument (try --help)"
    exit 1
end

opts = GetoptLong.new(
    ['--newip', '-i', GetoptLong::REQUIRED_ARGUMENT],
    ['--oldip', '-o', GetoptLong::REQUIRED_ARGUMENT],
    ['--help', '-h', GetoptLong::NO_ARGUMENT]
)

def help() 
    puts ""
    puts "   Usage #{$0} : "
    puts "\t--newip | -n \t Specify the newest ip (netmask accepted)"
    puts "\t--oldip | -o \t Specify the oldes ip (netmask accepted) you want to replace"
    puts "\t--vpc | -v \t Specify the vpc-id. Default is #{@vpcID}"
    puts "\tIf netmask is not specified, /32 will be used (just this ip)"
    puts "\t"
    puts "\t--help | -h \t This help"
    puts ""
    puts "\texample: #{$0} --newip 8.8.8.8 --oldip 4.4.4.4"
    puts "\texample: #{$0} --newip 8.8.8.8/28 --oldip 4.4.4.4/28"

end

opts.each do |opt, arg|
    case opt 
        when '--help'
            help()
            exit
        when '--newip'
            @newip=arg
        when '--oldip'
            @oldip=arg
    end
end

if !@newip
    puts "You should specify a new IP argument"
    exit
else
    if @newip !~ /\//
        @newip="#{@newip}/32"
    end
end

if !@oldip
    puts "You should specify an old IP argument"
    exit
else
    if @oldip !~ /\//
        @oldip="#{@oldip}/32"
    end
end

@secuList=Hash.new()

Aws.config.update({region: 'us-east-1',credentials: Aws::Credentials.new('AWS_ACCESS_KEY', 'AWS_SECRET_KEY'),})

@ec2SecurityGroups = Aws::EC2::SecurityGroup
@describeSecurityGroups = Aws::EC2::Types::DescribeSecurityGroupsRequest
@vpcSecurityGroup = Aws::EC2::Vpc

def getIpInfos()
    @vpcSecurityGroup.new(:id => "#{@vpcID}").security_groups.each do |securitygroup|
        theSecuID = securitygroup.id
        @listCIDR = Array.new()
        @ec2SecurityGroups.new(:id => "#{theSecuID}").ip_permissions.each do |rulesDetails|
            rulesDetails.ip_ranges.each do |rules|
                theCIDR = rules.cidr_ip
                if theCIDR =~ /#{@oldip}/
                    @listCIDR << {"ip_protocol" => "#{rulesDetails['ip_protocol']}","from_port" => rulesDetails['from_port'].to_i,"to_port" => rulesDetails['to_port'].to_i}
                else
                    next
                end
            end
            if @listCIDR.empty?
                next
            else
                @secuList["#{theSecuID}"]=@listCIDR
            end
        end
    end
end

def removeRules(sgID,proto,from,to,ip)
    @ec2SecurityGroups.new(:id => "#{sgID}").revoke_ingress({ip_protocol: "#{proto}",from_port:"#{from}", to_port:"#{to}" ,cidr_ip:"#{ip}"})
end

def addRules(sgID,proto,from,to,ip)
    @ec2SecurityGroups.new(:id => "#{sgID}").authorize_ingress({ip_protocol: "#{proto}",from_port:"#{from}", to_port:"#{to}" ,cidr_ip:"#{ip}"})
end

getIpInfos

if @secuList.count == 0
    puts "No security group to update. Your ip/netmask not found. Nothing to do!"
    exit
else
    puts "== replace starting =="
    @secuList.each do |secID, arrayRules|
        arrayRules.each do |rulesUpdate|
            removeRules(secID,rulesUpdate["ip_protocol"],rulesUpdate["from_port"],rulesUpdate["to_port"],@oldip)
            addRules(secID,rulesUpdate["ip_protocol"],rulesUpdate["from_port"],rulesUpdate["to_port"],@newip)
        end
        puts "Rules has been changed for the SG: #{secID}"
    end
    puts "== replace is finished =="
end


