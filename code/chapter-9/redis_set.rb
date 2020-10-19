require_relative './int_set'
require_relative './dict'

module BYORedis
  class RedisSet

    # How many times bigger should be the set compared to the requested size
    # for us to don't use the "remove elements" strategy? Read later in the
    # implementation for more info.
    # See: https://github.com/antirez/redis/blob/6.0.0/src/t_set.c#L609-L612
    SRANDMEMBER_SUB_STRATEGY_MUL = 3

    # How many times bigger should be the set compared to the remaining size
    # for us to use the "create new set" strategy? Read later in the
    # implementation for more info.
    # See: https://github.com/antirez/redis/blob/6.0.0/src/t_set.c#L413-416
    SPOP_MOVE_STRATEGY_MUL = 5

    attr_reader :cardinality, :underlying_structure

    def initialize
      @max_list_size = ENV['SET_MAX_ZIPLIST_ENTRIES'].to_i.then do |max|
        max <= 0 ? 256 : max
      end
      @underlying_structure = IntSet.new
      @cardinality = 0
    end

    def self.intersection(sets)
      # Sort the sets smallest to largest
      sets.sort_by!(&:cardinality)

      intersection_set = RedisSet.new
      # Iterate over the first set, if we find a set that does not contain it, discard

      sets[0].each do |member|
        present_in_all_other_sets = true
        sets[1..-1].each do |set|
          unless set.contains?(member)
            present_in_all_other_sets = false
            break
          end
        end
        # Otherwise, keep
        intersection_set.add(member) if present_in_all_other_sets
      end

      intersection_set
    end

    def self.union(sets)
      if sets.empty?
        RedisSet.new
      else
        union_set = RedisSet.new
        sets[0].each { |member| union_set.add(member) }
        sets[1..-1].each do |set|
          set.each { |member| union_set.add(member) }
        end

        union_set
      end
    end

    def self.difference(sets)
      first_set = sets[0]
      return RedisSet.new if first_set.nil?

      # Decide which algorithm to use
      algo_one_work = 0
      algo_two_work = 0
      sets.each do |other_set|
        algo_one_work += sets[0].cardinality
        algo_two_work += other_set ? other_set.cardinality : 0
      end
      # Directly from Redis:
      # Algorithm 1 has better constant times and performs less operations
      # if there are elements in common. Give it some advantage:
      algo_one_work /= 2
      diff_algo = (algo_one_work <= algo_two_work) ? 1 : 2

      if diff_algo == 1
        if sets.length > 1
          sets.sort_by! { |s| -1 * s.cardinality }
        end
        difference_1(sets)
      else
        difference_2(sets)
      end
    end

    def self.difference_1(sets)
      return RedisSet.new if sets.empty? || sets[0].nil?

      dest_set = RedisSet.new

      sets[0].each do |element|
        i = 0
        other_sets = sets[1..-1]
        while i < other_sets.length
          other_set = other_sets[i]
          # There's nothing to do when one of the sets does not exist
          next if other_set.nil?
          # If the other set contains the element then we know we don't want to add element to
          # the diff set
          break if other_set == self

          break if other_set.contains?(element)

          i += 1
        end

        if i == other_sets.length
          dest_set.add(element)
        end
      end

      dest_set
    end

    def self.difference_2(sets)
      return self if sets.empty? || sets[0].nil?

      dest_set = RedisSet.new

      # Add all the elements from the first set to the new one
      sets[0].each do |element|
        dest_set.add(element)
      end

      # Iterate over all the other sets and remove them from the first one
      sets[1..-1].each do |set|
        set.each do |member|
          dest_set.remove(member)
        end
      end

      dest_set
    end

    def add(member)
      if @underlying_structure.is_a?(IntSet)

        int_member = can_be_represented_as_int?(member)
        if int_member
          added = @underlying_structure.add(int_member)

          if added && @cardinality + 1 > @max_list_size
            convert_intset_to_dict
          end
        else
          convert_intset_to_dict
          added = add_to_dict_if_needed(member)
        end
      elsif @underlying_structure.is_a?(Dict)
        added = add_to_dict_if_needed(member)
      else
        raise "Unknown type for structure: #{ @underlying_structure }"
      end

      @cardinality += 1 if added

      added
    end

    def members
      case @underlying_structure
      when IntSet then @underlying_structure.members.map(&:to_s)
      when Dict then @underlying_structure.keys
      else raise "Unknown type for structure #{ @underlying_structure }"
      end
    end

    def pop
      case @underlying_structure
      when IntSet then
        popped = @underlying_structure.pop.to_s
        @cardinality -= 1
        popped
      when Dict then
        random_entry = @underlying_structure.random_entry
        @underlying_structure.delete(random_entry.key)
        @cardinality -= 1
        random_entry.key
      else raise "Unknown type for structure #{ @underlying_structure }"
      end
    end

    def pop_with_count(count)
      return [] if count.nil? || count == 0

      # Case 1: count is greater or equal to the size of the set, we return the whole thing
      if count >= @cardinality
        all_members = members
        clear
        return all_members
      end

      remaining = @cardinality - count
      if remaining * SPOP_MOVE_STRATEGY_MUL > count
        # Case 2: Count is small compared to the size of the set, we "just" pop random elements

        return count.times.map do
          pop
        end
      else
        # Case 3: count is big and close to the size of the set, we do the reverse, we pick
        # remaining elements, and they become the new set
        new_set = RedisSet.new
        remaining.times do
          new_set.add(pop)
        end
        result = members
        @underlying_structure = new_set.underlying_structure
        result
      end
    end

    def random_members_with_count(count)
      return [] if count.nil? || count == 0

      # Case 1: Count is negative, we return that many elements, ignoring duplicates
      if count < 0
        members = []
        (-count).times do
          members << random_member
        end

        return members
      end

      # Case 2: Count is positive and greater than the size, we return the whole thing
      return self if count >= @cardinality

      # For both case 3 & 4 we need a new set
      new_set = Dict.new
      # Case 3: Number of elements in the set is too small to grab n random distinct members
      # from it so we instead pick random elements to remove from it
      # Start by creating a new set identical to self and then remove elements from it
      if count * SRANDMEMBER_SUB_STRATEGY_MUL > @cardinality
        size = @cardinality
        each { |member| new_set.add(member, nil) }
        while size > count
          random_entry = new_set.random_entry
          new_set.delete(random_entry.key)
          size -= 1
        end
        return new_set.keys
      end

      # Case 4: The number of elements in the set is big enough in comparison to count so we
      # do the "classic" approach of picking count distinct elements
      added = 0
      while added < count
        member = random_member
        added += 1 if new_set.add(member, nil)
      end

      new_set.keys
    end

    def random_member
      case @underlying_structure
      when IntSet then Utils.integer_to_string(@underlying_structure.random_member)
      when Dict then
        random_entry = @underlying_structure.random_entry
        random_entry.key
      else raise "Unknown type for structure #{ @underlying_structure }"
      end
    end

    def empty?
      case @underlying_structure
      when IntSet then @underlying_structure.empty?
      when Dict then @underlying_structure.used == 0
      else raise "Unknown type for structure #{ @underlying_structure }"
      end
    end

    def contains?(member)
      return false if member.nil?

      case @underlying_structure
      when IntSet then
        if member.is_a?(Integer)
          member_as_int = member
        else
          member_as_int = Utils.string_to_integer_or_nil(member)
        end

        if member_as_int
          @underlying_structure.contains?(member_as_int)
        else
          false
        end
      when Dict then @underlying_structure.include?(member)
      else raise "Unknown type for structure #{ @underlying_structure }"
      end
    end

    def each(&block)
      case @underlying_structure
      when IntSet then @underlying_structure.each { |i| block.call(Utils.integer_to_string(i)) }
      when Dict then @underlying_structure.each(&block)
      else raise "Unknown type for structure #{ @underlying_structure }"
      end
    end

    def remove(member)
      case @underlying_structure
      when IntSet
        member_as_integer = Utils.string_to_integer_or_nil(member)
        if member_as_integer
          removed = @underlying_structure.remove(member_as_integer)
          @cardinality -= 1 if removed
          removed
        else
          false
        end
      when Dict
        removed = !@underlying_structure.delete_entry(member).nil?
        @cardinality -= 1 if removed
        removed
      else raise "Unknown type for structure #{ @underlying_structure }"
      end
    end

    private

    def clear
      @cardinality = 0
      @underlying_structure = IntSet.new
    end

    def add_to_dict_if_needed(member)
      present = @underlying_structure.include?(member)
      if present
        added = false
      else
        added = true
        @underlying_structure.add(member, nil)
      end

      added
    end

    def convert_intset_to_dict
      dict = Dict.new
      @underlying_structure.each do |member|
        dict[Utils.integer_to_string(member)] = nil
      end

      @underlying_structure = dict
    end

    def can_be_represented_as_int?(member)
      Utils.string_to_integer(member)
    rescue InvalidIntegerString
      false
    end
  end

  class SetSerializer

    def initialize(set)
      @set = set
    end

    def serialize
      response = ''
      @set.each do |member|
        response << "$#{ member.size }\r\n#{ member }\r\n"
      end

      response.prepend("*#{ @set.cardinality }\r\n")

      response
    end
  end
end
