require 'forwardable'
require 'addressable/template'
require 'hal_client/representation'
require 'hal_client/link'
require 'hal_client/curie_resolver'

class HalClient
  # Interprets parsed JSON
  class Interpreter
    extend Forwardable

    # Collection of reserved properties
    # https://tools.ietf.org/html/draft-kelly-json-hal-07#section-4.1
    RESERVED_PROPERTIES = ['_links', '_embedded'].freeze

    def initialize(parsed_json, hal_client)
      (fail InvalidRepresentationError,
            "Invalid HAL representation: #{parsed_json.inspect}") unless
        hashish?(parsed_json)

      @raw = parsed_json
      @hal_client = hal_client
    end

    # Returns hash of properties from `parsed_json`
    def extract_props()
      raw.reject{|k,_| RESERVED_PROPERTIES.include?(k) }
    end

    def extract_links()
      extract_embedded_links +  extract_basic_links
    end

    protected

    attr_reader :raw, :hal_client

    def hashish?(obj)
      obj.respond_to?(:[]) &&
        obj.respond_to?(:map)
    end

    def extract_basic_links
      raw
        .fetch("_links") { Hash.new }
        .flat_map { |rel, target_info|
          build_links(rel, target_info)
        }
        .compact
        .to_set
    end

    def extract_embedded_links
      raw
        .fetch("_embedded") { Hash.new }
        .flat_map { |rel, embedded_json|
          build_embedded_links(rel, embedded_json)
      }
        .compact
        .to_set
    end

    def build_links(rel, target_info)
      arrayify(target_info)
        .map { |info|
          if info["templated"]
            build_templated_link(rel, info)
          else
            build_direct_link(rel, info)
          end
        }
        .compact
    end

    def build_embedded_links(rel, targets_json)
      arrayify(targets_json)
        .map{ |target_json|
          target_repr = Representation.new(parsed_json: target_json, hal_client: hal_client)

          SimpleLink.new(rel: rel,
                         target: target_repr,
                         curie_resolver: curie_resolver)
        }

    rescue InvalidRepresentationError
      MalformedLink.new(rel: rel,
                        msg: "/_embedded/#{jpointer_esc(rel)} is invalid",
                        curie_resolver: curie_resolver)
    end

    def build_templated_link(rel, info)
      fail(InvalidRepresentationError) unless hashish?(info)

      target_pattern = info.fetch("href") { fail InvalidRepresentationError }

      TemplatedLink.new(rel: rel,
                        template: Addressable::Template.new(target_pattern),
                        curie_resolver: curie_resolver,
                        hal_client: hal_client)

    rescue InvalidRepresentationError
      MalformedLink.new(rel: rel,
                        msg: "/_links/#{jpointer_esc(rel)} is invalid",
                        curie_resolver: curie_resolver)
    end

    def build_direct_link(rel, info)
      fail InvalidRepresentationError unless hashish?(info)

      target_url = info.fetch("href") { fail InvalidRepresentationError }
      return nil unless target_url

      target_repr = Representation.new(href: target_url, hal_client: hal_client)

      SimpleLink.new(rel: rel,
                     target: target_repr,
                     curie_resolver: curie_resolver)

    rescue InvalidRepresentationError
      MalformedLink.new(rel: rel,
                        msg: "/_links/#{jpointer_esc(rel)} is invalid",
                        curie_resolver: curie_resolver)
    end

    def curie_resolver
      @curie_resolver ||= CurieResolver.new(raw.fetch("_links", {}).fetch("curies", []))
    end

    def hashish?(thing)
      thing.kind_of?(Hash) ||
        thing.respond_to?(:fetch) && thing.respond_to?(:key?)
    end

    def arrayify(obj)
      if Array === obj
        obj
      else
        [obj]
      end
    end

    def jpointer_esc(str)
      str.gsub "/", "~1"
    end

  end
end
