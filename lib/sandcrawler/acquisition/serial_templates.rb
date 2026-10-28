# frozen_string_literal: true

module Sandcrawler
  module Acquisition
    module SerialTemplates
      module_function

      def literal(path)
        path.b.dump
      end

      def capabilities(root, marker)
        [
          "r=#{literal(root)}",
          'begin;Dir.entries(r);a="entries";rescue;Dir.open(r){|d|d.read};a="open";end',
          'begin;File.directory?(r);b="directory";rescue;File.stat(r).directory?;b="stat";end',
          'begin;"A".bytes.each{|x|x};c="bytes";rescue;"A".each_byte{|x|x};c="each_byte";end',
          "puts #{literal("#{marker}CAP|")}+a+\"|\"+b+\"|\"+c"
        ].join(";")
      end

      def listing(path, capabilities, marker)
        listing = if capabilities[:list] == "entries"
                    "names=Dir.entries(r)"
                  else
                    "names=[];Dir.open(r){|d|while n=d.read;names<<n;end}"
                  end
        directory = if capabilities[:directory] == "directory"
                      'File.directory?(p+"/"+n)'
                    else
                      'File.stat(p+"/"+n).directory?'
                    end
        prefix = path.sub(%r{/+\z}, "")
        iterator = capabilities[:bytes] == "bytes" ? "record.bytes.each" : "record.each_byte"
        "r=#{literal(path)};p=#{literal(prefix)};#{listing};count=0;sum=0;names.each{|n|if n!=\".\" && n!=\"..\";" \
          "s=n;#{hex(capabilities)};record=(#{directory} ? \"D\" : \"F\")+\"|\"+h;" \
          "#{iterator}{|b|sum=(sum+b)%65536};count+=1;puts #{literal("#{marker}LIST|")}+record;end};" \
          "puts #{literal("#{marker}LISTEND|")}+count.to_s+\"|\"+sum.to_s"
      end

      def read_capability(path, marker)
        "f=File.open(#{literal(path)},\"r\");begin;begin;f.read(1);m=\"read\";rescue;f.getc;m=\"getc\";end;" \
          "puts #{literal("#{marker}READCAP|")}+m;ensure;f.close;end"
      end

      def transfer(path, capabilities, read_mode, marker)
        read = if read_mode == "read"
                 "s=f.read(256)"
               else
                 's="";256.times{c=f.getc;break if c.nil?;s+=(c.is_a?(Integer) ? c.chr : c)}'
               end
        "f=File.open(#{literal(path)},\"r\");begin;i=0;n=0;sum=0;loop{#{read};break if s.nil? || s.empty?;" \
          "#{hex(capabilities, checksum: true)};puts #{literal("#{marker}DATA|")}+i.to_s+\"|\"+h;" \
          "i+=1};puts #{literal("#{marker}END|")}+n.to_s+\"|\"+sum.to_s;ensure;f.close;end"
      end

      def hex(capabilities, checksum: false)
        iterator = capabilities[:bytes] == "bytes" ? "s.bytes.each" : "s.each_byte"
        "h=\"\";#{iterator}{|b|v=b.to_s(16);h+=(v.length==1 ? \"0\"+v : v)#{';n+=1;sum=(sum+b)%65536' if checksum}}"
      end
    end
  end
end
