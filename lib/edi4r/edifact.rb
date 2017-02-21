# encoding: US-ASCII

# UN/EDIFACT add-ons to EDI module,
# API to parse and create UN/EDIFACT data
#
# :include: ../../AuthorCopyright
#
# $Id: edifact.rb,v 1.10 2006/08/01 11:14:07 werntges Exp $
#--
# $Log: edifact.rb,v $
# Revision 1.10  2006/08/01 11:14:07  werntges
# Release 0.9.4.1 -- see ChangeLog
#
# Revision 1.9  2006/05/26 16:56:41  werntges
# V 0.9.3 snapshot. Many improvements (see ChangeLog), RDoc, more I-EDI support
#
# Revision 1.8  2006/05/01 22:23:55  werntges
# Preparing for 0.9.2: See ChangeLog for new features
#
# Revision 1.7  2006/04/28 14:31:50  werntges
# 0.9.1 snapshot
#
# Revision 1.6  2006/03/28 22:23:40  werntges
# changed to using symbols as parameter keys, e.g. :charset
# implemented as new module EDI::E, abandoning Interchange_E and alike
# bug fixes re. UNA (@una, setters)
#
# Revision 1.5  2006/03/22 16:52:42  werntges
# snapshot after edi4r-0.8.2.gem
#
# Revision 1.4  2004/02/19 17:31:52  heinz
# HWW: Snapshot after REMADV mapping
#
# Revision 1.3  2004/02/14 12:10:19  heinz
# HWW: Minor improvements
#
# Revision 1.2  2004/02/11 23:31:59  heinz
# HWW: First release after finishing basic tests
#
# Revision 1.1  2004/02/10 00:25:13  heinz
# Initial revision
#
#
# Derived from "edi.rb" V 1.11 on 2004-02-09 by HWW
#
# To-do list:
#	validate	- add functionality
#	charset		- check for valid chars (add UNOD-UNOZ)
#	UNT count	- compensate for empty segments which won't show!
#	MsgGroup	- improve support
#	NDB		- enable support of subsets
#	NDB		- support codelists
#	SV4		- Support for repetitions
#	SV4		- Support for new service segments
#	SV4		- Support for I-EDI releases
#++
#
# This is the UN/EDIFACT module of edi4r (hence '::E')
#
# It implements EDIFACT versions of classes Interchange, MsgGroup, Message, 
# Segment, CDE, and DE in sub-module 'E' of module 'EDI'.

module EDI::E

  #
  # Use pattern for allowed chars of UNOC charset if none given explicitly
  #
  Illegal_Charset_Patterns = Hash.new(/[^-A-Za-z0-9 .,()\/=!%"&*;<>'+:?\xa0-\xff]+/)
  Illegal_Charset_Patterns['UNOA'] =     /[^-A-Z0-9 .,()\/=!%"&*;<>'+:?]+/
  Illegal_Charset_Patterns['UNOB'] =  /[^-A-Za-z0-9 .,()\/=!%"&*;<>'+:?]+/
  # more to come...

  #########################################################################
  #
  # Utility: Separator method for UN/EDIFACT segments/CDEs
  # 
  # The given string typically comprises an EDIFACT segment or a CDE.
  # We want to split it into its elements and return those in an array.
  # The tricky part is the proper handling of character escaping!
  #
  # Examples:
  #  CDE = "1234:ABC:567" 	 --> ['1234','ABC','567']
  #  CDE = "1234::567"		 --> ['1234','','567']
  #  CDE = ":::SOMETEXT"	 --> ['','','','SOMETEXT']
  #  Seg = "TAG+1++2:3:4+A?+B=C" --> ['TAG','1','','2:3:4','A+B=C']
  #
  # NOTE: This function might be a good candidate for implementation in "C"
  #
  # Also see: ../../test/test_edi_split.rb
  #
  # str:: String to split
  # s::   Separator char (an Integer)
  # e::   Escape / release char (an Integer)
  # max:: Max. desired number of result items, default = all
  #
  # Returns:
  #   Array of split results (strings without their terminating separator)

  def edi_split( str, s, e, max=0 )
    results, item, start = [], '', 0
    while start < str.length do
      # match_at = index of next separator, or -1 if none found
      match_at = ((start...str.length).find{|i| str[i] == s}) || str.length
      item += str[start...match_at]
      # Count escapes in front of separator. No real separator if odd!
      escapes = count_escapes( item, e )
      if escapes & 1 == 1 # odd
        raise EDISyntaxError, "Pending escape char in #{str}" if match_at == str.length
        (escapes/2+1).times {item.chop!} # chop off duplicate escapes
        item << s # add separator as regular character
      else # even
        (escapes/2).times {item.chop!}  # chop off duplicate escapes
        results << item
        item = ''
      end
      start = match_at + 1
    end
    #
    # Do not return trailing empty items
    #
    results << item unless item.empty?
    return results if results.empty?
    while results.last.empty?; results.pop; end
    results
  end

  class EDISyntaxError < ArgumentError
  end

  def count_escapes( str, e ) # :nodoc:
    n = 0
    (str.length-1).downto(0) do |i|
      if str[i]==e 
        n += 1
      else
        return n
      end
    end
    n
  end

  module_function :edi_split, :count_escapes


  #########################################################################
  #
  # Here we extend class Time by some methods that help us maximize
  # its use in the UN/EDIFACT context.
  #
  # Basic idea: 
  # * Use the EDIFACT qualifiers of DE 2379 in DTM directly
  #   to parse dates and to create them upon output.
  # * Use augmented Time objects as values of DE 2380 instead of strings
  #
  # Currently supported formats: 101, 102, 201, 203, 204

  class ::Time
    attr_accessor :format

    def Time.edifact(str, fmt=102)
      msg = "Time.edifact: #{str} does not match format #{fmt}"
      case fmt.to_s
      when '101'
        rc = str =~ /(\d\d)(\d\d)(\d\d)(.+)?/
        raise msg unless rc and rc==0; warn msg if $4
        year = $1.to_i
        year += (year < 69) ? 2000 : 1900 # See ParseDate
        dtm = Time.local(year, $2, $3)

      when '102'
        rc = str =~ /(\d\d\d\d)(\d\d)(\d\d)(.+)?/
        raise msg unless rc and rc==0; warn msg if $4
        dtm = Time.local($1, $2, $3)

      when '201'
        rc = str =~ /(\d\d)(\d\d)(\d\d)(\d\d)(\d\d)(.+)?/
        raise msg unless rc and rc==0; warn msg if $6
        year = $1.to_i
        year += (year < 69) ? 2000 : 1900 # See ParseDate
        dtm = Time.local(year, $2, $3, $4, $5)

      when '203'
        rc = str =~ /(\d\d\d\d)(\d\d)(\d\d)(\d\d)(\d\d)(.+)?/
        raise msg unless rc and rc==0; warn msg if $6
        dtm = Time.local($1, $2, $3, $4, $5)

      when '204'
        rc = str =~ /(\d\d\d\d)(\d\d)(\d\d)(\d\d)(\d\d)(\d\d)(.+)?/
        raise msg unless rc and rc==0; warn msg if $7
        dtm = Time.local($1, $2, $3, $4, $5, $6)

      else
        raise "Time.edifact: Format #{fmt} not supported - sorry"
      end
      dtm.format = fmt.to_s
      dtm
    end

    alias to_s_orig to_s

    def to_s
      return to_s_orig unless @format
      case @format.to_s
      when '101'
        "%02d%02d%02d" % [year % 100, mon, day]
      when '102'
        "%04d%02d%02d" % [year, mon, day]
      when '201'
        "%02d%02d%02d%02d%02d" % [year % 100, mon, day, hour, min]
      when '203'
        "%04d%02d%02d%02d%02d" % [year, mon, day, hour, min]
      when '204'
        "%04d%02d%02d%02d%02d%2d" % [year, mon, day, hour, min, sec]
      else # Should never occur
        raise "Time.edifact: Format #{format
} not supported - sorry"
      end
    end
  end

  #########################################################################
  #
  # Class UNA is a model of UN/EDIFACT's UNA pseudo-segment.
  # It provides getters and setters that let you manipulate the six special
  # characters of UN/EDIFACT. Note that the chars are passed as integers,
  # i.e. ASCII codes.
  #
  class UNA < EDI::Object

    attr_reader :pattern_esc, :pattern_unesc # :nodoc:
    attr_reader :ce_sep, :de_sep, :rep_sep, :esc_char, :seg_term, :decimal_sign

    #
    # Sets the decimal sign. UN/EDIFACT allows only  ?, and ?.
    #
    def decimal_sign= (chr)
      chr = chr[0] if chr.is_a? String
      raise "Illegal decimal sign: #{chr}" unless chr==?. || chr==?,
      @decimal_sign = chr
      set_chars
    end

    #
    # Sets the composite data element separator. Default is ?:
    #
    def ce_sep= (chr)
      chr = chr[0] if chr.is_a? String
      @ce_sep = chr
      set_chars	# Update derived Regexp objects!
    end

    #
    # Sets the data element separator. Default is ?+
    #
    def de_sep= (chr)
      chr = chr[0] if chr.is_a? String
      @de_sep = chr
      set_chars	# Update derived Regexp objects!
    end

    #
    # Sets the repetition separator. Default is ?* .
    # Only applicable to Syntax Version 4 !
    #
    def rep_sep= (chr)
      raise NoMethodError, "Syntax version 4 required" unless root.version==4
      chr = chr[0] if chr.is_a? String
      @rep_sep = chr
      set_chars	# Update derived Regexp objects!
    end

    #
    # Sets the segment terminator. Default is ?'
    #
    def seg_term= (chr)
      chr = chr[0] if chr.is_a? String
      @seg_term = chr
      set_chars	# Update derived Regexp objects!
    end

    #
    # Sets the escape character. Default is ??
    #
    def esc_char= (chr)
      chr = chr[0] if chr.is_a? String
      @esc_char = chr
      set_chars	# Update derived Regexp objects!
    end

    #
    # Generates the UNA object
    # * Requires that "version" and "charset" of parent/root (Interchange)
    #   be already defined.
    # * Sets the UN/EDIFACT defaults if source string 'UNA......' not given
    #   
    def initialize( root, source=nil )
      super( root, root, 'UNA')

      raise "UNA.new requires 'version' in the interchange" unless root.version
      raise "UNA.new requires 'charset' in the interchange" unless root.charset

      if source =~ /^UNA(......)$/  # Take what's given
        @chars = $1

      elsif (source == nil or source.empty?) # Use EDIFACT default rules
        if root.version==2 and root.charset=='UNOB'
          @chars = "\x11\x12.? \x14"
        elsif root.version==4
          @chars = ":+.?*'"
        else
          @chars = ":+.? '"
        end
        
      else
        raise "This is not a valid UNA source string: #{source}"
      end

      @ce_sep, @de_sep, @decimal_sign, 
      @esc_char, @rep_sep, @seg_term = @chars.split('').map{|c| c[0]}
      set_patterns
    end

    def to_s
      'UNA'+@chars
    end

    private

    def set_chars
      @chars=[@ce_sep, @de_sep, @decimal_sign, @esc_char, @rep_sep, @seg_term ]
      @chars=@chars.map{|c| c.chr}.join('')
      # Prevent duplicates
      raise "Must not assign special char more than once!" if @chars=~/(.).*\1/
      set_patterns
    end

    #
    # Adjust match patterns anew when one of the UNA separators / special
    # characters is changed.
    #
    def set_patterns
      special_chars = [ @ce_sep, @de_sep, @esc_char, @seg_term ]
      special_chars.push @rep_sep if root.version == 4
      special_chars = special_chars.map{|c| c.chr}
      @pattern_esc = Regexp.new( [ '([', special_chars, '])' ].flatten.join)
      @pattern_unesc = Regexp.new( [ 
                                     '([^', @esc_char, ']?)', '[', @esc_char,
                                     ']([', special_chars,'])' 
                                   ].flatten.join )
      root.show_una = true
    end
  end

  #########################################################################
  #
  # Interchange: Class of the top-level objects of UN/EDIFACT data
  #
  class Interchange < EDI::Interchange

    attr_accessor :show_una
    attr_reader :e_linebreak, :e_indent # :nodoc:
    attr_reader :charset, :una
    attr_reader :messages_created, :groups_created


    @@interchange_defaults = {
      :i_edi => false, :charset => 'UNOB', :version => 3,
      :show_una => true, :una_string => nil,
      :sender => nil, :recipient => nil,
      :interchange_control_reference => '1', :application_reference => nil, 
      :interchange_agreement_id => nil,
      :acknowledgment_request => nil, :test_indicator => nil,
      :output_mode => :verbatim
    }
    @@interchange_default_keys = @@interchange_defaults.keys

    # Create an empty UN/EDIFACT interchange
    #
    # == Supported parameters (passed hash-style):
    #
    # === Essentials, should not be changed later
    # :charset ::  Sets S001.0001, default = 'UNOB'
    # :version ::  Sets S001.0002, default = 3
    # :i_edi ::    Interactive EDI mode, a boolean (UIB instead of UNB ...), default = false
    #
    # === Optional parameters affecting to_s, with corresponding setters
    # :show_una ::    Adds UNA sement to output, default = true
    # :output_mode :: See setter output_mode=(), default = :verbatim
    # :una_string ::  See class UNA for setters, default = nil
    #
    # === Optional UNB presets for your convenience, may be changed later
    # :sender ::    Presets DE S002/0004, default = nil
    # :recipient :: Presets DE S003/0010, default = nil
    # :interchange_control_reference :: Presets DE 0020, default = '1'
    # :application_reference ::         Presets DE 0026, default = nil
    # :interchange_agreement_id ::      Presets DE 0032, default = nil
    # :acknowledgment_request ::        Presets DE 0031, default = nil
    # :test_indicator ::                Presets DE 0035, default = nil
    #
    # === Notes
    # * Date and time in S004 are set to the current values automatically.
    # * Add or change any data element later. except those in S001.
    #
    # === Examples:
    # - ic = EDI::E::Interchange.new  # Empty interchange, default settings
    # - ic = EDI::E::Interchange.new(:charset=>'UNOC',:output_mode=>:linebreak)

    def initialize( user_par={} )
      super( user_par ) # just in case...
      if (illegal_keys = user_par.keys - @@interchange_default_keys) != []
        msg = "Illegal parameter(s) found: #{illegal_keys.join(', ')}\n"
        msg += "Valid param keys (symbols): #{@@interchange_default_keys.join(', ')}"
        raise ArgumentError, msg
      end
      par = @@interchange_defaults.merge( user_par )

      @messages_created = @groups_created = 0

      @syntax = 'E' # par[:syntax]	# E = UN/EDIFACT
      @e_iedi = par[:i_edi]
      @charset = par[:charset]
      @version = par[:version]
      @una = UNA.new(self, par[:una_string])
      self.output_mode = par[:output_mode]
      self.show_una = par[:show_una]

      check_consistencies
      init_ndb( @version )

      if @e_iedi  # Interactive EDI

        raise "I-EDI not supported yet"

        # Fill in what we already know about I-EDI:

        @header = new_segment('UIB')
        @trailer = new_segment('UIZ')
        @header.cS001.d0001 = par[:charset]
        @header.cS001.d0002 = par[:version]

        @header.cS002.d0004 = par[:sender] unless par[:sender].nil?
        @header.cS003.d0010 = par[:recipient] unless par[:recip].nil?
        @header.cS302.d0300 = par[:interchange_control_reference]
        # FIXME: More to do in S302...

        x= :test_indicator;           @header.d0035 = par[x] unless par[x].nil?

        t = Time.now
        @header.cS300.d0338 = t.strftime(par[:version]==4 ? '%Y%m%d':'%y%m%d')
        @header.cS300.d0314 = t.strftime("%H%M")
        
        @trailer.d0036 = 0
        ch, ct = @header.cS302, @trailer.cS302
        ct.d0300, ct.d0303, ct.d0051, ct.d0304 = ch.d0300, ch.d0303, ch.d0051, ch.d0304 
      else # Batch EDI

        @header = new_segment('UNB')
        @trailer = new_segment('UNZ')
        @header.cS001.d0001 = par[:charset]
        @header.cS001.d0002 = par[:version]
        @header.cS002.d0004 = par[:sender] unless par[:sender].nil?
        @header.cS003.d0010 = par[:recipient] unless par[:recip].nil?
        @header.d0020 = par[:interchange_control_reference]

        x= :application_reference;    @header.d0026 = par[x] unless par[x].nil?
        x= :acknowledgment_request;   @header.d0031 = par[x] unless par[x].nil?
        x= :interchange_agreement_id; @header.d0032 = par[x] unless par[x].nil?
        x= :test_indicator;           @header.d0035 = par[x] unless par[x].nil?

        t = Time.now
        @header.cS004.d0017 = t.strftime(par[:version]==4 ? '%Y%m%d':'%y%m%d')
        @header.cS004.d0019 = t.strftime("%H%M")
        
        @trailer.d0036 = 0
      end
    end


    #
    # Reads EDIFACT data from given stream (default: $stdin),
    # parses it and returns an Interchange object
    #
    def Interchange.parse( hnd=$stdin, auto_validate=true )
      ic = nil
      buf = hnd.read
      return ic if buf.empty?

      ic, segment_list = Interchange.parse_buffer( buf )
      # Remember to update ndb to SV4-1 now if d0076 of UNB/S001 tells so

      # Deal with 'trash' after UNZ

      if ic.is_iedi?
        init_seg = Regexp.new('^UIB'); tag_init = 'UIB'
        exit_seg = Regexp.new('^UIZ'); tag_exit = 'UIZ'
      else
        init_seg = Regexp.new('^UNB'); tag_init = 'UNB'
        exit_seg = Regexp.new('^UNZ'); tag_exit = 'UNZ'
      end
      
      last_seg = nil
      loop do
        last_seg = segment_list.pop
        case last_seg
        when /^[A-Z]{3}/ # Segment tag?
          unless last_seg =~ exit_seg
            raise "Parse error: #{tag_exit} is not last segment! Found: #{last_seg}"
          end
          break
        when /\n/, /\r\n/, ''
          # ignore linebreaks at end of file, do not warn.
        else
          warn "WARNING: Data found after #{tag_exit} segment - ignored!"
          warn "Found: \'#{last_seg}\'"
        end
      end
      trailer = Segment.parse(ic, last_seg, tag_exit)

      # Assure that there is only one UNB/UNZ or UIB/UIZ

      err_flag = false
      segment_list.each do |seg|
        if seg =~ init_seg
          warn "ERROR: Another interchange header found in file!"
          err_flag = true
        end
        if seg =~ exit_seg
          warn "ERROR: Another interchange trailer found in file!"
          err_flag = true
        end
      end
      raise "FATAL ERROR - exiting" if err_flag

      # OK, ready to deal with content now:

      case segment_list[0]
      when /^UNH/
        init_seg = Regexp.new('^UNH')
        exit_seg = Regexp.new('^UNT')
        group_mode = false
      when /^UNG/
        init_seg = Regexp.new('^UNG')
        exit_seg = Regexp.new('^UNE')
        group_mode = true
      when /^UIH/ # There is no 'UIG'!
        init_seg = Regexp.new('^UIH')
        exit_seg = Regexp.new('^UIT')
        group_mode = false
      else
        raise "Expected: UNH, UNG, or UIH. Found: #{segment_list[0]}"
      end
      
      while segbuf = segment_list.shift
        case segbuf

        when init_seg
          sub_list = Array.new
          sub_list.push segbuf

        when exit_seg
          sub_list.push segbuf	
          if group_mode
            ic.add( MsgGroup.parse(ic, sub_list), auto_validate )
          else
            ic.add( Message.parse(ic, sub_list), auto_validate )
          end

        else
          sub_list.push segbuf	
        end

      end # while

      # Finally add the trailer from the originally read data,
      # thereby overwriting the temporary interchange trailer.
      # Note that the temporary trailer got modified by add()ing 
      # to the interchange.
      ic.trailer = trailer
      ic
    end

    #
    # Read +maxlen+ bytes from $stdin (default) or from given stream
    # (UN/EDIFACT data expected), and peek into first segment (UNB/UIB).
    #
    # Returns an empty Interchange object with a properly header filled.
    #
    # Intended use: 
    #   Efficient routing by reading just UNB data: sender/recipient/ref/test
    #
    def Interchange.peek(hnd=$stdin, maxlen=128) # Handle to input stream
      buf = hnd.read( maxlen )
      return nil if buf.empty?
      ic, dummy = Interchange.parse_buffer( buf, 1 )

      # Create a dummy trailer
      tag = ic.is_iedi? ? 'UIZ' : 'UNZ'
      trailer_string = tag.dup << ic.una.de_sep << '0' << ic.una.de_sep << '0'
      ic.trailer= Segment.parse(ic, trailer_string, tag)

      ic
    end

    #
    # INTERNAL USE ONLY:
    # Turn buffer into array of segments (array size <= s_max),
    # read UNB/UIB, create an Interchange object with a header,
    # return this interchange and the array of segments
    #
    def Interchange.parse_buffer( buf, s_max=0 ) # :nodoc:
      case buf
        # UN/EDIFACT case
      when /^(UNA......)?\r?\n?U([IN])B.(UNO[A-Z]).([1-4])/
        par = @@interchange_defaults.dup
        par[:una_string], par[:charset], par[:version], par[:i_edi] =
          $1, $3, $4.to_i, $2=='I'
        ic = Interchange.new( par )
        buf.sub!(/^UNA....../,'') # remove pseudo segment
        
      else
        raise "Is this really UN/EDIFACT? File starts with: #{buf[0,23]}"
      end

      segments = EDI::E.edi_split(buf, ic.una.seg_term, ic.una.esc_char, s_max)
      # Remove <cr><lf> (some sources are not EDIFACT compliant)
      segments.each {|s| s.sub!(/\s*(.*)/, '\1')}
      ic.header = Segment.parse(ic, segments.shift, ic.is_iedi? ? 'UIB':'UNB')

      [ic, segments]
    end

    #
    # Returns +true+ if this is an I-EDI interchange (Interactive EDI)
    #
    def is_iedi?
      @e_iedi
    end

    # This method modifies the behaviour of method to_s():
    # UN/EDIFACT interchanges and their components are turned into strings
    # either "verbatim" (default) or in some more readable way.
    # This method corresponds to a parameter with same name at creation time.
    #
    # Valid values:
    #
    # :linebreak :: One-segment-per-line representation
    # :indented ::  Like :linebreak but with additional indentation 
    #               (2 blanks per hierarchy level).
    # :verbatim ::  No linebreak (default), ISO compliant
    # 
    def output_mode=( value )
      super( value )
      @e_linebreak = @e_indent = ''
      case value
      when :verbatim
        # NOP (default)
      when :linebreak
        @e_linebreak = "\n"
      when :indented
        @e_linebreak = "\n"
        @e_indent = '  '
      else
        raise "Unknown output mode '#{value}'. Supported modes: :linebreak, :indented, :verbatim (default)"
      end
    end


    # Add either a MsgGroup or Message object to the interchange.
    # Note: Don't mix both types!
    #
    # UNZ/UIZ counter DE 0036 is automatically incremented.

    def add( obj, auto_validate=true )
      super
      @trailer.d0036 += 1 #if @trailer # @trailer doesn't exist yet when parsing
      # FIXME: Warn/fail if UNH/UIH/UNG id is not unique (at validation?)
    end


    # Derive an empty message group from this interchange context.
    # Parameters may be passed hash-like. See MsgGroup.new for details
    #
    def new_msggroup(params={}) # to be completed ...
      @groups_created += 1
      MsgGroup.new(self, params)
    end

    # Derive an empty message from this interchange context.
    # Parameters may be passed hash-like. See Message.new for details
    #
    def new_message(params={})
      @messages_created += 1
      Message.new(self, params)
    end

    # Derive an empty segment from this interchange context
    # For internal use only (header / trailer segment generation)
    #
    def new_segment(tag) # :nodoc:
      Segment.new(self, tag)
    end


    # Parse a message group (when group mode detected)
    # Internal use only.

    def parse_msggroup(list) # :nodoc:
      MsgGroup.parse(self, list)
    end

    # Parse a message (when message mode detected)
    # Internal use only.

    def parse_message(list) # :nodoc:
      Message.parse(self, list)
    end

    # Parse a segment (header or trailer expected)
    # Internal use only.

    def parse_segment(buf, tag) # :nodoc:
      Segment.parse(self, buf, tag)
    end


    # Returns the string representation of the interchange.
    #
    # Type conversion and escaping are provided.
    # The UNA object is shown when +show_una+ is set to +true+ .
    # See +output_mode+ for modifiers. 

    def to_s
      s = show_una ? una.to_s + @e_linebreak : ''
      postfix = '' << una.seg_term << @e_linebreak
      s << super( postfix )
    end


    # Yields a readable, properly indented list of all contained objects,
    # including the empty ones. This may be a very long string!

    def inspect( indent='', symlist=[] )
      symlist << :una
      super
    end


    # Returns the number of warnings found, writes warnings to STDERR

    def validate( err_count=0 )
      if (h=self.size) != (t=@trailer.d0036)
        warn "Counter UNZ/UIZ, DE0036 does not match content: #{t} vs. #{h}"
        err_count += 1
      end
      if (h=@header.cS001.d0001) != @charset
        warn "Charset UNZ/UIZ, S001/0001 mismatch: #{h} vs. #@charset"
        err_count += 1
      end
      if (h=@header.cS001.d0002) != @version
        warn "Syntax version UNZ/UIZ, S001/0002 mismatch: #{h} vs. #@version"
        err_count += 1
      end
      check_consistencies

      if is_iedi?
        if (t=@trailer.cS302.d0300) != (h=@header.cS302.d0300)
          warn "UIB/UIZ mismatch in initiator ref (S302/0300): #{h} vs. #{t}"
          err_count += 1
        end
        # FIXME: Add more I-EDI checks
      else
        if (t=@trailer.d0020) != (h=@header.d0020)
          warn "UNB/UNZ mismatch in refno (DE0020): #{h} vs. #{t}"
          err_count += 1
        end
      end

      # FIXME: Check if messages/groups are uniquely numbered

      super
    end

    private

    #
    # Private method: Loads EDIFACT norm database
    #
    def init_ndb(d0002, d0076 = nil)
      @basedata = EDI::Dir::Directory.create(root.syntax,
                                             :d0002   => @version, 
                                             :d0076   => d0076, 
                                             :is_iedi => is_iedi?)
    end

    #
    # Private method: Check if basic UNB elements are set properly
    #
    def check_consistencies
      # FIXME - @syntax should be completely avoided, use sub-module name
      if not ['E'].include?(@syntax) # More anticipated here
        raise "#{@syntax} - syntax not supported!"
      end
      case @version
      when 1
        if @charset != 'UNOA'
          raise "Syntax version 1 permits only charset UNOA!"
        end
      when 2
        if not @charset =~ /UNO[AB]/
          raise "Syntax version 2 permits only charsets UNOA, UNOB!"
        end
      when 3
        if not @charset =~ /UNO[A-F]/
          raise "Syntax version 3 permits only charsets UNOA...UNOF!"
        end
      when 4
        # A,B: ISO 646 subsets, C-K: ISO-8859-x, X: ISO 2022, Y: ISO 10646-1
        if not @charset =~ /UNO[A-KXY]/
          raise "Syntax version 4 permits only charsets UNOA...UNOZ!"
        end
      else
        raise "#{@version} - no such syntax version!"
      end
      if @e_iedi and @version != 4
        raise "Inconsistent parameters - I-EDI requires syntax version 4!"
      end
      @illegal_charset_pattern = Illegal_Charset_Patterns['@version']
      # Add more rules ...
    end

  end

  #########################################################################
  #
  # Class EDI::E::MsgGroup
  #
  # This class implements a group of business documents of the same type
  # Its header unites features from UNB as well as from UNH.
  #
  class MsgGroup < EDI::MsgGroup

    attr_reader :messages_created

    @@msggroup_defaults = {
      :msg_type => 'ORDERS', :version => 'D', :release => '96A', 
      :resp_agency => 'UN', :assigned_code => nil # e.g. 'EAN008'
    }
    @@msggroup_default_keys = @@msggroup_defaults.keys
    
    # Creates an empty UN/EDIFACT message group
    # Don't use directly - use +new_msggroup+ of class Interchange instead!
    #
    # == First parameter
    #
    # This is always the parent object (an interchange object).
    # Use method +new_msggroup+ in the corresponding object instead
    # of creating message groups unattended - the parent reference
    # will be accounted for automatically.
    #
    # == Second parameter
    # 
    # List of supported hash keys:
    #
    # === UNG presets for your convenience, may be changed later
    #
    # :msg_type ::    Sets DE 0038, default = 'INVOIC'
    # :resp_agency :: Sets DE 0051, default = 'UN'
    # :version ::     Sets S008.0052, default = 'D'
    # :release ::     Sets S008.0054, default = '96A'
    #
    # === Optional parameters, required depending upon use case
    #
    # :assigned_code ::   Sets S008.0057 (subset), default = nil
    # :sender ::          Presets DE S006/0040, default = nil
    # :recipient ::       Presets DE S007/0044, default = nil
    # :group_reference :: Presets DE 0048, auto-incremented
    #
    # == Notes
    #
    # * The functional group reference number in UNG and UNE (0048) is set 
    #   automatically to a number that is unique for this message group and
    #   the running process (auto-increment).
    # * The counter in UNG (0060) is set automatically to the number
    #   of included messages.
    # * The trailer segment (UNE) is generated automatically.
    # * Whenever possible, <b>avoid writing to the counters of
    #   the message header or trailer segments</b>!

    def initialize( p, user_par={} )
      super( p, user_par )
      @messages_created = 0
 
      if user_par.is_a? Hash
        preset_group( user_par )
        @header = new_segment('UNG')
        @trailer = new_segment('UNE')
        @trailer.d0060 = 0

        @header.d0038 = @name
        @header.d0051 = @resp_agency
        cde = @header.cS008
        cde.d0052 = @version
        cde.d0054 = @release
        cde.d0057 = @subset

        @header.cS006.d0040 = user_par[:sender]    || root.header.cS002.d0004
        @header.cS007.d0044 = user_par[:recipient] || root.header.cS003.d0010
        @header.d0048 = user_par[:group_reference] || p.groups_created
        #      @trailer.d0048 = @header.d0048

        t = Time.now
        @header.cS004.d0017 = t.strftime(p.version==4 ? '%Y%m%d':'%y%m%d')
        @header.cS004.d0019 = t.strftime("%H%M")
        
      elsif user_par.is_a? Segment

        @header = user_par
        raise "UNG expected, #{@header.name} found!" if @header.name != 'UNG'
        @header.parent = self
        @header.root = self.root

        # Assign a temporary UNE segment
        de_sep = root.una.de_sep
        @trailer = Segment.parse(root, 'UNE' << de_sep << '0' << de_sep << '0')

        s008 = @header.cS008
        @name = @header.d0038
        @version = s008.d0052
        @release = s008.d0054
        @resp_agency = @header.d0051
        @subset = s008.d0057
      else
        raise "First parameter: Illegal type!"
      end

    end


    # Internal use only!

    def preset_group(user_par) # :nodoc:
      if (illegal_keys = user_par.keys - @@msggroup_default_keys) != []
        msg = "Illegal parameter(s) found: #{illegal_keys.join(', ')}\n"
        msg += "Valid param keys (symbols): #{@@msggroup_default_keys.join(', ')}"
        raise ArgumentError, msg
      end
      par = @@msggroup_defaults.merge( user_par )

      @name = par[:msg_type]
      @version = par[:version]
      @release = par[:release]
      @resp_agency = par[:resp_agency]
      @subset = par[:assigned_code]
      # FIXME: Eliminate use of @version, @release, @resp_agency, @subset
      #        They get outdated whenever their UNG counterparts are changed
      #        Try to keep @name updated, or pass it a generic name
    end


    def MsgGroup.parse (p, segment_list) # List of segments
      grp = p.new_msggroup(:msg_type => 'DUMMY')

      # We now expect a sequence of segments that comprises one group, 
      # starting with UNG and ending with UNE, and with messages in between.
      # We process the UNG/UNE envelope separately, then work on the content.

      header  = grp.parse_segment(segment_list.shift, 'UNG')
      trailer = grp.parse_segment(segment_list.pop,   'UNE')

      init_seg = Regexp.new('^UNH')
      exit_seg = Regexp.new('^UNT')
      
      while segbuf = segment_list.shift
        case segbuf

        when init_seg
          sub_list = Array.new
          sub_list.push segbuf

        when exit_seg
          sub_list.push segbuf	
          grp.add grp.parse_message(sub_list)

        else
          sub_list.push segbuf	
        end
      end

      grp.header  = header
      grp.trailer = trailer
      grp
    end
    

    def new_message(params={})
      @messages_created += 1
      Message.new(self, params)
    end

    def new_segment(tag) # :nodoc:
      Segment.new(self, tag)
    end


    def parse_message(list) # :nodoc:
      Message.parse(self, list)
    end

    def parse_segment(buf, tag) # :nodoc:
      Segment.parse(self, buf, tag)
    end


    def add( msg )
      super
      @trailer.d0060 = @trailer.d0060.to_i if @trailer.d0060.is_a? String
      @trailer.d0060 += 1
    end


    def to_s
      postfix = '' << root.una.seg_term << root.e_linebreak
      super( postfix )
    end


    def validate( err_count=0 )

      # Consistency checks

      if (a=@trailer.d0060) != (b=self.size)
        warn "UNE: DE 0060 (#{a}) does not match number of messages (#{b})"
        err_count += 1
      end
      a, b = @trailer.d0048, @header.d0048
      if a != b
        warn "UNE: DE 0048 (#{a}) does not match reference in UNG (#{b})"
        err_count += 1
      end
      
      # FIXME: Check if messages are uniquely numbered

      super
    end

  end


  #########################################################################
  #
  # Class EDI::E::Message
  #
  # This class implements a single business document according to UN/EDIFACT

  class Message < EDI::Message
    #    private_class_method :new

    @@message_defaults = {
      :msg_type => 'ORDERS', :version => 'D', :release => '96A', 
      :resp_agency => 'UN', :assigned_code => nil # e.g. 'EAN008'
    }
    @@message_default_keys = @@message_defaults.keys
    
    # Creates an empty UN/EDIFACT message
    # Don't use directly - use +new_message+ of class Interchange or MsgGroup instead!
    #
    # == First parameter
    #
    # This is always the parent object, either a message group
    # or an interchange object.
    # Use method +new_message+ in the corresponding object instead
    # of creating messages unattended, and the parent reference
    # will be accounted for automatically.
    #
    # == Second parameter, case "Hash"
    # 
    # List of supported hash keys:
    #
    # === Essentials, should not be changed later
    #
    # :msg_type ::    Sets S009.0065, default = 'ORDERS'
    # :version ::     Sets S009.0052, default = 'D'
    # :release ::     Sets S009.0054, default = '96A'
    # :resp_agency :: Sets S009.0051, default = 'UN'
    #
    # === Optional parameters, required depending upon use case
    #
    # :assigned_code :: Sets S009.0057 (subset), default = nil
    #
    # == Second parameter, case "Segment"
    #
    # This mode is only used internally when parsing data.
    #
    # == Notes
    #
    # * The counter in UNH (0062) is set automatically to a
    #   number that is unique for the running process.
    # * The trailer segment (usually UNT) is generated automatically.
    # * Whenever possible, <b>avoid write access to the 
    #   message header or trailer segments</b>!

    def initialize( p, user_par={} )
      super( p, user_par )

      # First param is either a hash or segment UNH
      # - If Hash:    Build UNH from given parameters
      # - If Segment: Extract some crucial parameters
      if user_par.is_a? Hash
        preset_msg( user_par )
        par = {
          :d0065 => @name, :d0052=> @version, :d0054=> @release, 
          :d0051 => @resp_agency, :d0057 => @subset, :is_iedi => root.is_iedi?
        }
        @maindata = EDI::Dir::Directory.create(root.syntax, par )
 
        if root.is_iedi?
          @header = new_segment('UIH')
          @trailer = new_segment('UIT')
          cde = @header.cS306
#          cde.d0113 = @sub_id
          @header.d0340 = p.messages_created
        else
          @header = new_segment('UNH')
          @trailer = new_segment('UNT')
          cde = @header.cS009
          @header.d0062 = p.messages_created
        end
        cde.d0065 = @name
        cde.d0052 = @version
        cde.d0054 = @release
        cde.d0051 = @resp_agency
        cde.d0057 = @subset

      elsif user_par.is_a? Segment
        @header = user_par
        raise "UNH expected, #{@header.name} found!" if @header.name != 'UNH'
        # I-EDI support to be added!
        @header.parent = self
        @header.root = self.root
        @trailer = Segment.new(root, 'UNT') # temporary
        s009 = @header.cS009
        @name = s009.d0065
        @version = s009.d0052
        @release = s009.d0054
        @resp_agency = s009.d0051
        @subset = s009.d0057
        par = {
          :d0065 => @name, :d0052=> @version, :d0054=> @release, 
          :d0051 => @resp_agency, :d0057 => @subset, :is_iedi => root.is_iedi?
        }
        @maindata = EDI::Dir::Directory.create(root.syntax, par )
      else
        raise "First parameter: Illegal type!"
      end

      @trailer.d0074 = 2 if @trailer  # Just UNH and UNT so far
    end

    #
    # Derive a new segment with the given name from this message context.
    # The call will fail if the message name is unknown to this message's
    # UN/TDID (not in EDMD/IDMD).
    #
    # == Example:
    #    seg = msg.new_segment( 'BGM' )
    #    seg.d1004 = '220'
    #    # etc.
    #    msg.add seg
    #
    def new_segment( tag )
      Segment.new(self, tag)
    end

    # Internal use only!

    def parse_segment(buf, tag) # :nodoc:
      Segment.parse(self, buf, tag)
    end

    # Internal use only!

    def preset_msg(user_par) # :nodoc:
      if (illegal_keys = user_par.keys - @@message_default_keys) != []
        msg = "Illegal parameter(s) found: #{illegal_keys.join(', ')}\n"
        msg += "Valid param keys (symbols): #{@@message_default_keys.join(', ')}"
        raise ArgumentError, msg
      end

      # Use UNG as source for defaults if present
      ung = parent.header
      if parent.is_a?(MsgGroup) && ung.d0038
        s008 = ung.cS008
        par = {
          :msg_type=> ung.d0038, :version=> s008.d0052, :release=> s008.d0054,
          :resp_agency => ung.d0051, :assigned_code => s008.d0057
        }.merge( user_par )
      else
        par = @@message_defaults.merge( user_par )
      end

      @name = par[:msg_type]
      @version = par[:version]
      @release = par[:release]
      @resp_agency = par[:resp_agency]
      @subset = par[:assigned_code]
      # FIXME: Eliminate use of @version, @release, @resp_agency, @subset
      #        They get outdated whenever their UNH counterparts are changed
      #        Try to keep @name updated, or pass it a generic name
    end


    # Returns a new Message object that contains the data of the
    # strings passed in the +segment_list+ array. Uses the context
    # of the given +parent+ object and configures message as a child.

    def Message.parse (parent, segment_list)

      if parent.root.is_iedi?
        h, t, re_t = 'UIH', 'UIT', /^UIT/
      else
        h, t, re_t = 'UNH', 'UNT', /^UNT/
      end

      # Segments comprise a single message
      # Temporarily assign a parent, or else service segment lookup fails
      header  = parent.parse_segment(segment_list.shift, h)
      msg     = parent.new_message(header)
      trailer = msg.parse_segment( segment_list.pop, t )

      segment_list.each do |segbuf|
        seg = Segment.parse( msg, segbuf )
        if segbuf =~ re_t # FIXME: Should that case ever occur?
          msg.trailer = seg
        else
          msg.add(seg)
        end
      end
      msg.trailer = trailer
      msg
    end


    #
    # Add a previously derived segment to the end of this message (append)
    # Make sure that all mandatory elements have been supplied.
    #
    # == Notes
    #
    # * Strictly add segments in the sequence described by this message's
    #   branching diagram!
    #
    # * Adding a segment will automatically increase the corresponding
    #   counter in the message trailer.
    #
    # == Example:
    #    seg = msg.new_segment( 'BGM' )
    #    seg.d1004 = '220'
    #    # etc.
    #    msg.add seg
    #
    def add( seg )
      super
      @trailer.d0074 = @trailer.d0074.to_i if @trailer.d0074.is_a? String
      @trailer.d0074 += 1	# What if new segment is/remains empty??
    end


    def validate( err_count=0 )
      # Check sequence of segments against library,
      # thereby adding location information to each segment

      par = {
        :d0065 => @name, :d0052=> @version, :d0054=> @release, 
        :d0051 => @resp_agency, :d0057 => @subset, 
        :d0002 => root.version, :is_iedi => root.is_iedi?,
        :d0076 => nil  # SV 4-1 support still missing here
      }
      diag = EDI::Diagram::Diagram.create( root.syntax, par )
      ni = EDI::Diagram::NodeInstance.new(diag)

      ni.seek!( @header )
      @header.update_with( ni )
      each do |seg| 
        if ni.seek!(seg)
          seg.update_with( ni )
        else
          # FIXME: Do we really have to fail here, or would a "warn" suffice?
          raise "seek! failed for #{seg.name} when starting at #{ni.name}"
        end 
      end
      ni.seek!( @trailer )
      @trailer.update_with( ni )


      # Consistency checks

      if (a=@trailer.d0074) != (b=self.size+2)
        warn "DE 0074 (#{a}) does not match number of segments (#{b})"
        err_count += 1
      end

      if root.is_iedi?
        a, b = @trailer.d0340, @header.d0340
      else
        a, b = @trailer.d0062, @header.d0062
      end
      if a != b
        warn "Trailer reference (#{a}) does not match header reference (#{b})"
        err_count += 1
      end

      if parent.is_a? MsgGroup
        ung = parent.header; s008 = ung.cS008; s009 = header.cS009
        a, b = s009.d0065, ung.d0038
        if a != b
          warn "Message type (#{a}) does not match that of group (#{b})"
          err_count += 1
        end
        a, b = s009.d0052, s008.d0052
        if a != b
          warn "Message version (#{a}) does not match that of group (#{b})"
          err_count += 1
        end
        a, b = s009.d0054, s008.d0054
        if a != b
          warn "Message release (#{a}) does not match that of group (#{b})"
          err_count += 1
        end
        a, b = s009.d0051, ung.d0051
        if a != b
          warn "Message responsible agency (#{a}) does not match that of group (#{b})"
          err_count += 1
        end
        a, b = s009.d0057, s008.d0057
        if a != b
          warn "Message association assigned code (#{a}) does not match that of group (#{b})"
          err_count += 1
        end

      end

      # Now check each segment
      super( err_count )
    end


    def to_s
      postfix = '' << root.una.seg_term << root.e_linebreak
      super( postfix )
    end

  end


  #########################################################################
  #
  # Class EDI::E::Segment
  #
  # This class implements UN/EDIFACT segments like BGM, NAD etc.,
  # including the service segments UNB, UNH ...
  #

  class Segment < EDI::Segment

    # A new segment must have a parent (usually, a message). This is the
    # first parameter. The second is a string with the desired segment tag.
    #
    # Don't create segments without their context - use Message#new_segment()
    # instead.

    def initialize(p, tag)
      super( p, tag )

      each_BCDS(tag) do |entry|
        id = entry.name
        status = entry.status

        # FIXME: Code redundancy in type detection - remove later!
        case id
        when /[CES]\d{3}/		# Composite
          add new_CDE(id, status)
        when /\d{4}/		# Simple DE
          add new_DE(id, status, fmt_of_DE(id))
        else			# Should never occur
          raise "Not a legal DE or CDE id: #{id}"
        end
      end
    end


    def new_CDE(id, status)
      CDE.new(self, id, status)
    end


    def new_DE(id, status, fmt)
      DE.new(self, id, status, fmt)
    end


    # Reserved for internal use

    def Segment.parse (p, buf, tag_expected=nil)
      # Buffer contains a single segment
      obj_list = EDI::E::edi_split( buf, p.root.una.de_sep, p.root.una.esc_char )
      tag = obj_list.shift 		  # First entry must be the segment tag

      raise "Illegal tag: #{tag}" unless tag =~ /[A-Z]{3}/
        if tag_expected and tag_expected != tag
          raise "Wrong segment name! Expected: #{tag_expected}, found: #{tag}"
        end

      seg = p.new_segment(tag)
      seg.each {|obj| obj.parse( obj_list.shift ) }
      seg
      # Error handling needed here if obj_list is not exhausted now!
    end


    def to_s
      s = ''
      return s if empty?

      rt = self.root

      indent = rt.e_indent * (self.level || 0)
      s << indent << name << rt.una.de_sep
      skip_count = 0
      each {|obj| 
        if obj.empty?
          skip_count += 1
        else
          if skip_count > 0
            s << rt.una.de_sep.chr * skip_count
            skip_count = 0
          end
          s << obj.to_s
          skip_count += 1
        end
      }
      s
    end


    # Some exceptional setters, required for data consistency

    # Don't change DE 0001! d0001=() raises an exception when called.
    def d0001=( value ); fail "Charset not modifiable!"; end

    # Don't change DE 0002! d0002=() raises an exception when called.
    def d0002=( value ); fail "EDIFACT Syntax version not modifiable!"; end

    # Setter for DE 0020 in UNB & UNZ (interchange control reference)
    def d0020=( value )
      return super unless self.name=~/UN[BZ]/
      parent.header['0020'].first.value = value
      parent.trailer['0020'].first.value = value
    end

    # Setter for DE 0048 in UNE & UNG (group reference)
    def d0048=( value )
      return super unless self.name=~/UN[GE]/
      parent.header['0048'].first.value = value
      parent.trailer['0048'].first.value = value
    end

    # Setter for DE 0062 in UNH & UNT (message reference number)
    def d0062=( value ) # UNH
      return super unless self.name=~/UN[HT]/
      parent.header['0062'].first.value = value
      parent.trailer['0062'].first.value = value
    end

    # Setter for DE 0340 in UIH & UIT (message reference number)
    def d0340=( value ) # UIH
      return super unless self.name=~/UI[HT]/
      parent.header['0340'].first.value = value
      parent.trailer['0340'].first.value = value
    end

  end


  #########################################################################
  #
  # Class EDI::E::CDE
  #
  # This class implements UN/EDIFACT composite data elements C507 etc.,
  # including the service CDEs S001, S009 ...
  #
  # For internal use only.

  class CDE < EDI::CDE

    def initialize(p, name, status)
      super(p, name, status)

      each_BCDS(name) do |entry|
        id = entry.name
        status = entry.status
        # FIXME: Code redundancy in type detection - remove later!
        if id =~ /\d{4}/
          add new_DE(id, status, fmt_of_DE(id))
        else				# Should never occur
          raise "Not a legal DE: #{id}"
        end
      end
    end

    def new_DE(id, status, fmt)
      DE.new(self, id, status, fmt)
    end


    def parse (buf)	# Buffer contains content of a single CDE
      return nil unless buf
      obj_list = EDI::E::edi_split( buf, root.una.ce_sep, root.una.esc_char )
      each {|obj| obj.parse( obj_list.shift ) }
      # FIXME: Error handling needed here if obj_list is not exhausted now!
    end


    def to_s
      rt = self.root
      s = ''; skip_count = 0
      ce_sep = rt.una.ce_sep.chr
      each {|de| 
        if de.empty?
          skip_count += 1
        else
          if skip_count > 0
            s << ce_sep * skip_count
            skip_count = 0
          end
          s << de.to_s
          skip_count += 1
        end
      }
      s
    end

  end


  #########################################################################
  #
  # Class EDI::E::DE
  #
  # This class implements UN/EDIFACT data elements 1004, 2005 etc.,
  # including the service DEs 0001, 0004, ...
  #
  # For internal use only.

  class DE < EDI::DE

    def initialize( p, name, status, fmt )
      super( p, name, status, fmt )
      raise "Illegal DE name: #{name}" unless name =~ /\d{4}/
        # check if supported format syntax
        # check if supported status value
    end

    
    # Generate the DE content from the given string representation.
    # +buf+ contains a single DE string, possibly escaped

    def parse( buf, already_escaped=false )
      return nil unless buf
      return @value = nil if buf.empty?
      @value = already_escaped ? buf : unescape(buf)
      if format[0] == ?n
        # Normalize decimal sign
        @value.sub!(/,/, '.')
        # Select appropriate Numeric, FIXME: Also match exponents!
        self.value = @value=~/\d+\.\d+/ ? @value.to_f : @value.to_i
      end
      @value
    end


    def to_s( no_escape=false )
      return '' if empty?
      s = if @value.is_a? Numeric
            # Adjust decimal sign
            super().sub(/[.,]/, root.una.decimal_sign.chr)
          else
            super().to_s
          end
      no_escape ? s : escape(s)
    end


    # The proper method to assign values to a DE.
    # The passed value must respond to +to_i+ .

    def value=( val )
      # Suppress trailing decimal part if Integer value
      ival = val.to_i
      val = ival if val.is_a? Float and val == ival
      super
    end


    private

    def escape (str) 
      rt = self.root
      raise "Must have a root to do this" if rt == nil

      esc = rt.una.esc_char.chr
      esc << ?\\ if esc == '\\' # Special case if backslash!
                   
      if rt.charset == 'UNOA'
        # Implicit conversion to uppercase - convenient, 
        # but could be argued against!
        str.upcase.gsub(rt.una.pattern_esc, esc+'\1')
      else
        str.gsub(rt.una.pattern_esc, esc+'\1')
      end
    end

    def unescape (str)
      rt = self.root
      raise "Must have a root to do this" if rt == nil
      str.gsub(rt.una.pattern_unesc, '\1\2')
    end
  end

end # module EDI
