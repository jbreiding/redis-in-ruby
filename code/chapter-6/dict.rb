require_relative './siphash'
require_relative './dict_entry'
require_relative './hash_table'

module Redis
  class Dict

    INITIAL_SIZE = 4
    MAX_SIZE = 2**63

    attr_reader :hash_tables

    def initialize(random_bytes)
      @hash_tables = [ HashTable.new(0), HashTable.new(0) ]
      @random_bytes = random_bytes
      @rehashidx = -1
    end

    def main_table
      @hash_tables[0]
    end

    def rehash_milliseconds(millis)
      start = Time.now.to_f * 1000
      rehashes = 0
      while rehash(100) == 1
        rehashes += 100
        delta = Time.now.to_f * 1000 - start

        break if delta > millis
      end
      delta = Time.now.to_f * 1000 - start

      rehashes
    end

    def resize
      return if rehashing?

      minimal = main_table.used
      if minimal < INITIAL_SIZE
        minimal = INITIAL_SIZE
      end
      expand(minimal)
    end

    def expand(size)
      return if rehashing? || main_table.used > size

      real_size = next_power(size)

      return if real_size == main_table.size

      new_hash_table = HashTable.new(real_size)

      # Is this the first initialization? If so it's not really a rehashing
      # we just set the first hash table so that it can accept keys.
      if main_table.table.nil?
        @hash_tables[0] = new_hash_table
      else
        @hash_tables[1] = new_hash_table
        @rehashidx = 0
      end
    end

    def include?(key)
      !get(key).nil?
    end

    def add(key, value)
      index = key_index(key)

      rehash_step if rehashing?

      table = rehashing? ? @hash_tables[1] : @hash_tables[0]
      entry = table.table[index]

      while entry
        break if entry.key == key

        entry = entry.next
      end

      if entry.nil?
        entry = DictEntry.new(key, value)
        entry.next = table.table[index]
        table.table[index] = entry
        table.used += 1
      else
        entry.value = value
      end
    end
    alias []= add

    def get(key)
      return if @hash_tables[0].used == 0 && @hash_tables[1].used == 0

      rehash_step if rehashing?

      hash = SipHash.digest(@random_bytes, key)
      (0..1).each do |i|
        table = @hash_tables[i]
        index = hash & table.sizemask

        entry = table.table[index]

        while entry
          return entry.value if entry.key == key

          entry = entry.next
        end

        break unless rehashing?
      end
    end
    alias [] get

    def delete(key)
      return if @hash_tables[0].used == 0 && @hash_tables[1].used == 0

      rehash_step if rehashing?

      hash_key = SipHash.digest(@random_bytes, key)
      (0..1).each do |i|
        table = @hash_tables[i]
        index = hash_key & table.sizemask
        entry = table.table[index]
        previous_entry = nil

        while entry
          if entry.key == key
            if previous_entry
              previous_entry.next = entry.next
            else
              table.table[index] = entry.next
            end
            table.used -= 1
            return entry
          end
          previous_entry = entry
          entry = entry.next
        end
        break unless rehashing?
      end
    end

    def each
      @hash_tables.each do |table|
        table.each do |bucket|
          next if bucket.nil?

          yield bucket.key, bucket.value until bucket.next.nil?
        end
      end
    end

    private

    def key_index(key)
      expand_if_needed
      hash = SipHash.digest(@random_bytes, key)
      index = nil

      (0..1).each do |i|
        table = @hash_tables[i]
        index = hash & table.sizemask

        break unless rehashing?
      end

      index
    end

    def rehash(n)
      empty_visits = n * 10
      return 0 unless rehashing?

      while n > 0 && main_table.used != 0
        n -= 1
        entry = nil
        while main_table.table[@rehashidx].nil?
          @rehashidx += 1
          empty_visits -= 1
          if empty_visits == 0
            return 1
          end
        end
        entry = main_table.table[@rehashidx]
        while entry
          next_entry = entry.next
          idx = SipHash.digest(@random_bytes, entry.key) & @hash_tables[1].sizemask

          entry.next = @hash_tables[1].table[idx]
          @hash_tables[1].table[idx] = entry
          @hash_tables[0].used -= 1
          @hash_tables[1].used += 1
          entry = next_entry
        end
        main_table.table[@rehashidx] = nil
        @rehashidx += 1
      end

      if main_table.used == 0
        @hash_tables[0] = @hash_tables[1]
        @hash_tables[1] = HashTable.new(0)
        @rehashidx = -1
        return 0
      end

      1
    end

    def rehashing?
      @rehashidx != -1
    end

    def expand_if_needed
      return if rehashing?

      if main_table.empty?
        expand(INITIAL_SIZE)
      elsif main_table.used >= main_table.size
        expand(main_table.size * 2)
      end
    end

    def next_power(size)
      # Ruby has practically no limit to how big an integer can be, because under the hood the
      # Integer class allocates the necessary resources to go beyond what could fit in a 64 bit
      # integer.
      # That being said, let's still copy what Redis does, since it makes sense to have an
      # explicit limit about how big our Dicts can get
      i = INITIAL_SIZE
      return MAX_SIZE if i > MAX_SIZE

      loop do
        return i if i >= size

        i *= 2
      end
    end

    def rehash_step
      rehash(1)
    end
  end
end
