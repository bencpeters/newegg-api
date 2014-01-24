module Newegg
  class Api

    attr_accessor :conn, :_stores, :_categories, :_id

    def initialize
      self._stores = []
    end
    
    #
    # retrieve an active connection or establish a new connection
    #
    # @ returns [Faraday::Connection] conn to the web service
    #
    def connection
      self.conn ||= Faraday.new(:url => 'http://www.ows.newegg.com') do |faraday|
        faraday.request :url_encoded            # form-encode POST params
        #faraday.response :logger                # log requests to STDOUT
        faraday.adapter Faraday.default_adapter # make requests with Net::HTTP
      end      
    end
    
    #
    # retrieve and populate a list of available stores
    #
    def stores
      return self._stores if not self._stores.empty?
      response = api_get("Stores.egg")
      stores = JSON.parse(response.body)
      stores.each do |store|
        self._stores <<  Newegg::Store.new(store['Title'], store['StoreDepa'], store['StoreID'], store['ShowSeeAllDeals'])
      end
      self._stores
    end

    #
    # retrieve the best matching store_id by name
    #
    # @param [String] name of the store
    #
    def get_store_by_name(name)
      return nil if name.nil?
      name = name.sub(/notebook*/i, 'laptop') 
      # Groupings help increase matching accuracy. Might be overkill though
      store = search_for_name(name, stores, :title, 
                              [/hardware/i,
                               /ultrabook/i,
                               /pc/i,
                               /laptop/i,
                               /notebook/i,
                               /electronic/i,
                               /software/i,
                               /gam*/i,
                               /cell*/i,
                               /phone/i,
                               /home/i,
                               /outdoor/i,
                               /auto/i,
                               /office/i,
                               /accessories/i,
                               /services/i,
                               /market*/i
      ])
    end

    #
    # Same as get_store_by_name, but returns nil or store_id rather than full store
    # object
    #
    # @param [String] name of the store to look for
    #
    def get_store_id_by_name(name)
      cat = get_store_by_name(name)
      cat.store_id unless cat.nil?
    end
    

    #
    # retrieve the best matching category by name from all the categories that match the
    # store_id (or optionally provide a list of categories to search within)
    #
    # @param [String] name of the category to look for
    # @param [optional, String] store_id to look in for categories
    #
    def get_category_by_name(name, store_id)
      return nil if name.nil?
      categories = categories store_id
      cat = search_for_name(name, categories, :description)
    end

    #
    # Same as get_category_by_name, but returns nil or category_id rather than full category
    # object
    #
    # @param [String] name of the category to look for
    # @param [optional, String] store_id to look in for categories
    #
    def get_category_id_by_name(*args)
      cat = get_category_by_name(*args)
      cat.category_id unless cat.nil?
    end
    
    #
    # retrieve and populate list of categories for a given store_id
    #
    # @param [Integer] store_id of the store
    #
    def categories(store_id)
      return [] if store_id.nil?

      response = api_get("Stores.egg", "Categories", store_id)
      categories = JSON.parse(response.body)
      categories = categories.collect do |category|
        Newegg::Category.new(category['Description'], category['CategoryType'], category['CategoryID'],
                             category['StoreID'], category['ShowSeeAllDeals'], category['NodeId'])
      end
      
      categories
    end  
    
    #
    # retrieves information necessary to search for products, given the store_id, category_id, node_id
    #
    # @param [Integer] store_id of the store
    # @param [Integer] category_id of the store
    # @param [Integer] node_id of the store
    #
    def navigate(store_id, category_id, node_id)
      response = api_get("Stores.egg", "Navigation", "#{store_id}/#{category_id}/#{node_id}")
      categories = JSON.parse(response.body)
    end
    
    #
    # retrieves a single page of products given a query specified by an options hash. See options below.
    # node_id, page_number, and an optional sorting method
    #
    # @param [Integer] store_id, from @api.navigation, returned as StoreID
    # @param [Integer] category_id from @api.navigation, returned as CategoryType
    # @param [Integer] sub_category_id from @api.navigation, returned as CategoryID
    # @param [Integer] node_id from @api.navigation, returned as NodeId
    # @param [Integer] page_number of the paginated search results, returned as PaginationInfo from search
    # @param [String] sort style of the returned search results, default is FEATURED
    # @param [String] keywords   
    #
    def search(options={})
      options.delete_if{|k,v| v.nil?}
      options = {store_id: -1, category_id: -1, sub_category_id: -1, node_id: -1, page_number: 1, sort: "FEATURED",
                 keywords: ""}.merge(options)
      request = {
          'IsUPCCodeSearch'      => false,
          'IsSubCategorySearch'  => options[:sub_category_id] > 0,
          'isGuideAdvanceSearch' => false,
          'StoreDepaId'          => options[:store_id],
          'CategoryId'           => options[:category_id],
          'SubCategoryId'        => options[:sub_category_id],
          'NodeId'               => options[:node_id],
          'BrandId'              => -1,
          'NValue'               => "",
          'Keyword'              => options[:keywords],
          'Sort'                 => options[:sort],
          'PageNumber'           => options[:page_number]
      }

      JSON.parse(api_post("Search.egg", "Advanced", request).body, {quirks_mode: true})
    end

    #
    # retrieve product information given an item number
    #
    # @param [String] item_number of the product
    #
    def specifications(item_number)
      JSON.parse(api_get("Products.egg", item_number, "Specification").body)
    end
    
    
    private
    
    #
    # GET: {controller}/{action}/{id}/
    #
    # @param [String] controller
    # @param [optional, String] action
    # @param [optional, String] id
    #
    def api_get(controller, action = nil, id = nil)
      uri = String.new

      if action && id
        uri = "/#{controller}/#{action}/#{id}"
      else
        uri = "/#{controller}/"
      end

      response = self.connection.get(uri)
      
      case code = response.status.to_i
      when 400..499
        raise(Newegg::NeweggClientError, "error, #{code}: #{response.inspect}")
      when 500..599
        raise(Newegg::NeweggServerError, "error, #{code}: #{response.inspect}")
      else
        response
      end
    end

    #
    # POST: {controller}/{action}/
    #
    # @param [String] controller
    # @param [String] action
    # @param [Hash] opts
    #
    def api_post(controller, action, opts={})
      response = self.connection.post do |request|
        request.url "/#{controller}/#{action}/"
        request.headers['Content-Type'] = 'application/json'
        request.headers['Accept']       = 'application/json'
        request.headers['Api-Version']  = '2.2'
        request.body = opts.to_json
      end

      case code = response.status.to_i
      when 400..499
        raise(Newegg::NeweggClientError, "error, #{code}: #{response.inspect}")
      when 500..599
        raise(Newegg::NeweggServerError, "error, #{code}: #{response.inspect}")
      else
        response
      end
    end

    #
    # Perform fuzzy search for the name on the specified list
    #
    # @param [String] name to look for
    # @param [Array] list of possible names
    # @param [Symbol] field of each item to search in for the name
    # @param [optional, Symbol] list of groupings to improve search performance
    #
    def search_for_name(name, list, field, groupings=[])
      fz = FuzzyMatch.new(list, read: field, groupings: groupings)
      fz.find(name)
    end
    
  end
end
