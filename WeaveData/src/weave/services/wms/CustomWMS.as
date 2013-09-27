package weave.services.wms
{
	import flash.display.Bitmap;
	import flash.net.URLRequest;
	
	import mx.rpc.events.FaultEvent;
	import mx.rpc.events.ResultEvent;
	
	import org.openscales.proj4as.ProjConstants;
	
	import weave.api.WeaveAPI;
	import weave.api.getCallbackCollection;
	import weave.api.primitives.IBounds2D;
	import weave.api.registerLinkableChild;
	import weave.api.reportError;
	import weave.compiler.StandardLib;
	import weave.core.LinkableNumber;
	import weave.core.LinkableString;
	import weave.core.LinkableVariable;
	import weave.data.ProjectionManager;
	import weave.primitives.Bounds2D;
	import weave.utils.AsyncSort;

	public class CustomWMS extends AbstractWMS
	{
		public function CustomWMS()
		{
			_currentTileIndex = new WMSTileIndex();
			getCallbackCollection(this).triggerCallbacks();
		}
		
		override public function getProjectionSRS():String
		{
			return tileProjectionSRS.value;
		}
		
		override public function getAllowedBounds(output:IBounds2D):void
		{
			output.reset();
			var coords:Array = tileBounds.getSessionState() as Array;
			if (coords)
				output.setBounds.apply(null, coords);
			
			if (output.isUndefined())
			{
				ProjectionManager.getMercatorTileBoundsInLatLong(output);
				WeaveAPI.ProjectionManager.transformBounds("EPSG:4326", tileProjectionSRS.value, output);
			}
		}
		
		public const tileBounds:LinkableVariable = registerLinkableChild(this, new LinkableVariable(Array, verifyTileBoundsArray));
		private function verifyTileBoundsArray(coords:Array):Boolean
		{
			return coords && coords.length == 4 && StandardLib.getArrayType(coords) == Number;
		}
		
		public const wmsURL:LinkableString = registerLinkableChild(this,new LinkableString(),getImageAttributes);
		public const tileProjectionSRS:LinkableString = registerLinkableChild(this,new LinkableString("EPSG:3857"));
		public const maxZoom:LinkableNumber = registerLinkableChild(this,new LinkableNumber(18));
		
		// reusable objects
		private const _tempCoord:Coordinate = new Coordinate(0,0,0); 
		private const _tempBounds:Bounds2D = new Bounds2D();
		private const _tempAllowedBounds:Bounds2D = new Bounds2D(); 
		private const _tempDataBounds:Bounds2D = new Bounds2D(); 
		private const _tempScreenBounds:Bounds2D = new Bounds2D();
		
		private var _imageHeight:Number = NaN;
		private var _imageWidth:Number = NaN;
		
		private var imageAttributesSet:Boolean= false;
		
		
		private function getImageAttributes():void
		{
			if(!wmsURL.value)
				return;
			
			//http://tiles.domain.com/layer/{z}/{x}/{y}.png
			getAllowedBounds(_tempDataBounds);
			_tempScreenBounds.setBounds(0, 0, 256, 256);
			
			var basicReq:String = getTileUrl(new Coordinate(0,0,0), _tempDataBounds, _tempScreenBounds);
			var instance:CustomWMS = this;
			WeaveAPI.URLRequestUtils.getContent(
				this,
				new URLRequest(basicReq),
				function(event:ResultEvent,token:Object=null):void
				{
					_imageWidth = (event.result as Bitmap).width;
					_imageHeight = (event.result as Bitmap).height;
					imageAttributesSet = true;
					getCallbackCollection(instance).triggerCallbacks();
				},
				function(event:FaultEvent,token:Object=null):void
				{
					//setting defaults values of 256 if there is an error in the request
					_imageWidth = 256;
					_imageHeight = 256;
					imageAttributesSet = true;
					getCallbackCollection(instance).triggerCallbacks();
				}
				
			)
		
		}
		
		override public function requestImages(dataBounds:IBounds2D, screenBounds:IBounds2D, preferLowerQuality:Boolean = false, layerLowerQuality:Boolean = false):Array
		{
			if(_currentTileIndex == null || !wmsURL.value || !imageAttributesSet)
				return [];

			getAllowedBounds(_tempAllowedBounds);
			var i:int
			
			// first determine zoom level using all of the data bounds in lat/lon
			setTempCoordZoomLevel(dataBounds, screenBounds, preferLowerQuality); // this sets _tempCoord.zoom 
			var zoomScale:Number = Math.pow(2, _tempCoord.z);
			
			// cancel all pending requests which aren't of this zoom level
			for (i = 0; i < _pendingTiles.length; ++i)
			{
				var pendingTile:WMSTile = _pendingTiles[i] as WMSTile;
				if (pendingTile.zoomLevel != _tempCoord.z)
				{
					pendingTile.cancelDownload(); // cancel download
					delete _urlToTile[pendingTile.request.url];
					_pendingTiles.splice(i--, 1); // remove from the array and decrement i
				}
			}
			
			// now determine the data bounds we need to covert in lat/lon
			_tempDataBounds.copyFrom(dataBounds);
			_tempAllowedBounds.constrainBounds(_tempDataBounds, false);
			WeaveAPI.ProjectionManager.transformBounds(tileProjectionSRS.value, "EPSG:4326", _tempDataBounds);
			
			// calculate min and max tile x and y for the zoom level
			dataBoundsToTileXY(_tempDataBounds, zoomScale);
			
			// if the tile range is unreasonable, cut it down to a more reasonable range
			var maxTileRangeX:int = screenBounds.getXCoverage() / _imageWidth + 2;
			var maxTileRangeY:int = screenBounds.getYCoverage() / _imageHeight + 2;
			if (_tempDataBounds.getWidth() > maxTileRangeX)
			{
				trace(debugId(this), 'adjusting tile X coverage from', _tempDataBounds.getWidth(), 'to', maxTileRangeX);
				_tempDataBounds.setWidth(maxTileRangeX);
				_tempDataBounds.setXCenter(int(_tempDataBounds.getXCenter()));
			}
			if (_tempDataBounds.getHeight() > maxTileRangeY)
			{
				trace(debugId(this), 'adjusting tile Y coverage from', _tempDataBounds.getHeight(), 'to', maxTileRangeY);
				_tempDataBounds.setHeight(maxTileRangeY);
				_tempDataBounds.setYCenter(int(_tempDataBounds.getYCenter()));
			}

			var xTileMin:Number = _tempDataBounds.xMin;
			var yTileMin:Number = _tempDataBounds.yMin;
			var xTileMax:Number = _tempDataBounds.xMax;
			var yTileMax:Number = _tempDataBounds.yMax;
			
			tileXYToData(_tempDataBounds, zoomScale);
			_tempAllowedBounds.constrainBounds(_tempDataBounds);
			
			
			// get tiles we need using the map's projection because the tiles' bounds must be in this projection
			var lowerQualTiles:Array = _currentTileIndex.getTiles(_tempDataBounds, 0, _tempCoord.z - 1);
			var completedTiles:Array = _currentTileIndex.getTiles(_tempDataBounds, _tempCoord.z, _tempCoord.z);
			outerLoop: for (var x:Number = xTileMin; x < xTileMax; ++x)
			{
				for (var y:Number = yTileMin; y < yTileMax; ++y)
				{
					if (_pendingTiles.length >= 100)
						break outerLoop;
					
					_tempDataBounds.setBounds(x, y, x + 1, y + 1);
					tileXYToData(_tempDataBounds, zoomScale);
					
					_tempCoord.y = y;
					_tempCoord.x = x;
					
					// if the coordinate is wrapped around, we don't want it
//					if (_mapProvider.sourceCoordinate(_tempCoord).equalTo(_tempCoord) == false)
//						continue;
					
					// get the tile URLs
					_tempScreenBounds.copyFrom(_tempDataBounds)
					dataBounds.projectCoordsTo(_tempScreenBounds, screenBounds);
					var requestString:String = getTileUrl(_tempCoord, _tempDataBounds, _tempScreenBounds);
					if(requestString == null)
						continue;
					if (_urlToTile[requestString] != undefined)
						continue;
					
					var urlRequest:URLRequest = new URLRequest(requestString);
					// note that thisTileMercator is still in Mercator coords
					var newTile:WMSTile = registerLinkableChild(this, new WMSTile(_tempDataBounds, _imageWidth, _imageHeight, urlRequest));
					newTile.zoomLevel = _tempCoord.z; // need to manually set it so tileIndex queries work
					_urlToTile[requestString] = newTile;
					_pendingTiles.push(newTile);
					downloadImage(newTile);
				}
			}
			
			var tiles:Array;
			if (layerLowerQuality)
				tiles = lowerQualTiles.concat(completedTiles);
			else
				tiles = completedTiles;
			AsyncSort.sortImmediately(tiles, tileSortingComparison);
			return tiles;
		}
		
		/**
		 * This function will convert a bounds in data coordinates to tile coordinates.
		 * 
		 * @param inputAndOutput the input/output buffer.
		 * @param zoomScale The value 2^zoom where zoom is the zoom level.
		 */
		private function dataBoundsToTileXY(inputAndOutput:Bounds2D, zoomScale:Number):void
		{
			inputAndOutput.makeSizePositive();
			if (tileProjectionSRS.value == 'EPSG:3857')
			{
				inputAndOutput.xMin = zoomScale * (inputAndOutput.xMin + 180) / 360.0; 
				inputAndOutput.xMax = zoomScale * (inputAndOutput.xMax + 180) / 360.0; 
				
				var latRadians:Number = inputAndOutput.yMin * Math.PI / 180;
				inputAndOutput.yMin = zoomScale * (1 - (Math.log(Math.tan(latRadians) + (1 / Math.cos(latRadians))) / Math.PI)) / 2.0;
				latRadians = inputAndOutput.yMax * Math.PI / 180;
				inputAndOutput.yMax = zoomScale * (1 - (Math.log(Math.tan(latRadians) + (1 / Math.cos(latRadians))) / Math.PI)) / 2.0;
			}
			else
			{
				getAllowedBounds(_tempAllowedBounds);
				_tempBounds.setBounds(0, 0, zoomScale, zoomScale);
				_tempAllowedBounds.projectCoordsTo(inputAndOutput, _tempBounds);
			}
			
			// force integer values
			inputAndOutput.makeSizePositive();
			inputAndOutput.xMin = Math.floor(inputAndOutput.xMin);
			inputAndOutput.yMin = Math.floor(inputAndOutput.yMin);
			inputAndOutput.xMax = Math.ceil(inputAndOutput.xMax);
			inputAndOutput.yMax = Math.ceil(inputAndOutput.yMax);
			
			// although this may allow the max values to be zoomScale, which is 1 larger than number of tiles,
			// it's not a problem because the tile starting at zoomScale,zoomScale is never requested.
			_tempBounds.setBounds(0, 0, zoomScale, zoomScale); 
			_tempBounds.constrainBounds(inputAndOutput, false);
		}
		
		/**
		 * This function will convert bounds from tile x,y coordinates to Latitude and Longitude coordinates.
		 * @param inputAndOutput The input/output buffer.
		 * @param zoomScale The value 2^zoom.
		 */
		private function tileXYToData(inputAndOutput:Bounds2D, zoomScale:Number):void
		{
			if (tileProjectionSRS.value == 'EPSG:3857')
			{
				inputAndOutput.xMin = 360 * (inputAndOutput.xMin / zoomScale) - 180.0;
				inputAndOutput.xMax = 360 * (inputAndOutput.xMax / zoomScale) - 180.0;
				
				var latRadians:Number = Math.atan(ProjConstants.sinh(Math.PI * (1 - 2 * inputAndOutput.yMin / zoomScale)));
				inputAndOutput.yMin = latRadians * 180.0 / Math.PI;
				latRadians = Math.atan(ProjConstants.sinh(Math.PI * (1 - 2 * inputAndOutput.yMax / zoomScale)));
				inputAndOutput.yMax = latRadians * 180.0 / Math.PI;
				
				inputAndOutput.makeSizePositive();
				WeaveAPI.ProjectionManager.transformBounds('EPSG:4326', 'EPSG:3857', inputAndOutput);
			}
			else
			{
				getAllowedBounds(_tempAllowedBounds);
				_tempBounds.setBounds(0, 0, zoomScale, zoomScale);
				_tempBounds.projectCoordsTo(inputAndOutput, _tempAllowedBounds);
			}
		}
		
		public const creditInfo:LinkableString = registerLinkableChild(this,new LinkableString(""));
		override public function getCreditInfo():String
		{
			return creditInfo.value;
		}
		
		
		/**
		 * This function sets the value of _tempCoord.zoom.
		 */
		private function setTempCoordZoomLevel(dataBounds:IBounds2D, screenBounds:IBounds2D, lowerQuality:Boolean):void
		{
			var requestedPrecision:Number = dataBounds.getArea() / screenBounds.getArea(); 
			if (lowerQuality == true)
				requestedPrecision *= 4; // go one level higher, which means twice the data width and height => 4 times
			
			getAllowedBounds(_tempAllowedBounds);
			var worldArea:Number = _tempAllowedBounds.getArea();
			var imageArea:int = _imageWidth* _imageHeight;
			var higherQualZoomLevel:int = int.MAX_VALUE;
			var lowerQualZoomLevel:int = int.MAX_VALUE;
			var numTiles:Number;
			var tileArea:Number;
			var tempPrecision:Number;
			_tempCoord.z = 1;
			
			// very few providers have a zoom of 0, so the loop starts at 1 to prevent enforcement later
			for (var i:int = 1; i <= maxZoom.value; ++i) // 20 is max provided in ModestMaps Library
			{
				numTiles = Math.pow(2, 2 * i); // 2^(2n) tiles at zoom level n
				tileArea = worldArea / numTiles;
				tempPrecision = tileArea / imageArea;
				if (tempPrecision < requestedPrecision)
				{
					higherQualZoomLevel = i;
					lowerQualZoomLevel = Math.max(i - 1, 1); // one level down or the minimum
					break;
				}
			}
			
			// compare the two qualities--the closer one is the one we want.
			var higherPrecision:Number = (worldArea / Math.pow(2, 2 * higherQualZoomLevel)) / imageArea;
			var lowerPrecision:Number = (worldArea / Math.pow(2, 2 * lowerQualZoomLevel)) / imageArea;
			if ((lowerPrecision - requestedPrecision) < (requestedPrecision - higherPrecision))
				_tempCoord.z = lowerQualZoomLevel;
			else
				_tempCoord.z = higherQualZoomLevel;
		}
		
		private function getTileUrl(coord:Coordinate, data:IBounds2D, screen:IBounds2D):String
		{
			if (!wmsURL || !wmsURL.value)
				return null;
			
			return StandardLib.replace(wmsURL.value, 
				'{x}', String(coord.x),
				'{y}', String(coord.y),
				'{z}', String(coord.z),
				'{bbox}', [data.getXMin(), data.getYMin(), data.getXMax(), data.getYMax()].join(','),
				'{size}', [screen.getXCoverage(), screen.getYCoverage()].join(',')
			);
		}
		
		/**
		 * This function will download the image data for a tile.
		 * 	
		 * @param tile The tile whose bitmap will be downloaded.
		 */
		public function downloadImage(tile:WMSTile):void
		{
			tile.downloadImage(handleImageDownload, handleImageDownloadFault, tile);
		}
		
		/**
		 * This function is called when an image is done downloading. The image is then cached and saved.
		 * 
		 * @param event The result event.
		 * @param token The tile.
		 */
		private function handleImageDownload(event:ResultEvent, tile:WMSTile):void
		{
			tile.bitmapData = (event.result as Bitmap).bitmapData;
			handleTileDownload(tile);
		}
		
		/**
		 * This function reports an error downloading an image. A download may fail with a valid URL.
		 * 
		 * @param event The fault event.
		 * @param token The tile.
		 */
		private function handleImageDownloadFault(event:FaultEvent, tile:WMSTile):void
		{
			tile.bitmapData = null; // a plotter should handle this
			reportError(event);
			
			/** 
			 * @TODO This may not be appropriate because a download with a valid URL may fail.
			 * It may be a better idea to try again once, and if it fails, never try again.
			 **/
			
			handleTileDownload(tile);
		}
		
		/**
		 * This is a private method used for sorting an array of WMSTiles.
		 */ 
		private function tileSortingComparison(a:WMSTile, b:WMSTile):int
		{
			// if a is lower quality (lower zoomLevel), it goes before
			if (a.zoomLevel < b.zoomLevel)
				return -1;
			else if (a.zoomLevel == b.zoomLevel)
				return 0;
			else
				return 1;			
		}
	}
}

internal class Coordinate
{
	public function Coordinate(x:Number, y:Number, z:Number)
	{
		this.x = x, this.y = y, this.z = z;
	}
	public var x:int, y:int, z:int;
}