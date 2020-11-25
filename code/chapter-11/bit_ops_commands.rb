require_relative './bit_ops'

module BYORedis
  module BitOpsUtils
    def self.validate_offset(string)
      error_message = 'ERR bit offset is not an integer or out of range'
      offset = Utils.validate_integer_with_message(string, error_message)

      if offset >= 0
        offset
      else
        raise ValidationError, error_message
      end
    end

    def self.validate_bit(string)
      error_message = 'ERR bit is not an integer or out of range'
      bit_value = Utils.validate_integer_with_message(string, error_message)

      if (bit_value & ~1) == 0 # equivalent to bit_value == 0 || bit_value == 1
        bit_value
      else
        raise ValidationError, error_message
      end
    end
  end

  class GetBitCommand < BaseCommand
    def call
      Utils.assert_args_length(2, @args)
      string = @db.lookup_string(@args[0])
      offset = BitOpsUtils.validate_offset(@args[1])

      RESPInteger.new(BitOps.new(string).get_bit(offset))
    end

    def self.describe
      Describe.new('getbit', 3, [ 'readonly', 'fast' ], 1, 1, 1,
                   [ '@read', '@bitmap', '@fast' ])
    end
  end

  class SetBitCommand < BaseCommand
    def call
      Utils.assert_args_length(3, @args)
      string = @db.lookup_string(@args[0])
      offset = BitOpsUtils.validate_offset(@args[1])
      bit = BitOpsUtils.validate_bit(@args[2])

      if string.nil?
        string = ''
        @db.data_store[@args[0]] = string
      end
      old_value = BitOps.new(string).set_bit(offset, bit)

      RESPInteger.new(old_value)
    end

    def self.describe
      Describe.new('setbit', 3, [ 'write', 'denyoom' ], 1, 1, 1,
                   [ '@write', '@bitmap', '@slow' ])
    end
  end

  class BitOpCommand < BaseCommand
    def call
      Utils.assert_args_length_greater_than(2, @args)
      operation = @args.shift
      case operation.downcase
      when 'and'
        dest = @args.shift
        first_key = @args.shift
        rest = @args.map { |key| @db.lookup_string(key) }
        first_string = @db.lookup_string(first_key)

        if first_string.nil?
          res = nil
          raise 'not done yet'
        else
          res = first_string.dup
          rest.each do |other_string|
            i = 0
            while i < res.length && i < other_string.length
              res_byte = res[i].ord
              other_byte = other_string[i].ord
              res[i] = (res_byte & other_byte).chr
              i += 1
            end

            while i < res.length || i < other_string.length
              res_byte = res[i]&.ord || 0
              other_byte = other_string[i]&.ord || 0

              res[i] = (res_byte & other_byte).chr
              i += 1
            end
            # Check for leftovers, fill with 0s since 0 & whatever is 0
          end
          @db.data_store[dest] = res
          # RESPBulkString.new(res)
          RESPInteger.new(res.length)
        end

      when 'or' then 1
      when 'xor' then 1
      when 'not' then 1
      else raise SyntaxError
      end
    end

    def self.describe
      Describe.new('bitop', -4, [ 'write', 'denyoom' ], 2, -1, 1,
                   [ '@write', '@bitmap', '@slow' ])
    end
  end

  class BitCountCommand < BaseCommand
    def call
    end

    def self.describe
      Describe.new('bitcount', -2, [ 'readonly' ], 1, 1, 1,
                   [ '@read', '@bitmap', '@slow' ])
    end
  end

  class BitPosCommand < BaseCommand
    def call
    end

    def self.describe
      Describe.new('bitpos', -3, [ 'readonly' ], 1, 1, 1,
                   [ '@read', '@bitmap', '@slow' ])
    end
  end

  class BitFieldCommand < BaseCommand
    def call
    end

    def self.describe
      Describe.new('bitfield', -2, [ 'write', 'denyoom' ], 1, 1, 1,
                   [ '@read', '@bitmap', '@slow' ])
    end
  end
end
