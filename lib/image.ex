defmodule Image do
  @moduledoc """
  `Image` is based upon the fabulous
  [vix](https://hex.pm/packages/vix) library that provides a [libvips](https://www.libvips.org)
  wrapper for Elixir.

  `Image` is intended to provide well-documented common image processing functions in
  an idiomatic Elixir functional style as a layer above the very comprehensive set
  of functions in `Vix` and `libvips`.

  In a very simple image resizing
  [benchmark](https://github.com/kipcole9/image/blob/main/bench/image_resize.exs),
  `Image` is approximately 2 to 3 times faster than `Mogrify` and uses about 5 times
  less memory.

  """

  alias Vix.Vips.{Operation, MutableImage}
  alias Vix.Vips.Image, as: Vimage

  alias Image.{Exif, Xmp, Complex, Options, Color, Interpretation, BlendMode}
  alias Image.Options.{Resize, Compose, Open}

  @typedoc """
  A 512 bit binary hash of an image.

  Useful for comparing the similarity of
  two images. See `Image.dhash/1` and
  `Image.hamming_distance/2`.
  """
  @type image_hash :: binary()

  # Default radius of rounded corners
  @default_round_corner_radius 50

  # Standard size of an avatar image, at least for
  # this library
  @default_avatar_size 180

  # if the ratio between width and height differs
  # by less than this amount, consider the image
  # to be square
  @square_when_ratio_less_than 0.0

  @typedoc """
  The valid rendering intent values. For all
  functions that take an optional intent
  parameter the default is `:perceptual`.

  ## Perceptual Intent

  Perceptual rendering is used to process photographic
  type images. This intent processes the colors so that
  the output reproduction is pleasing. This process
  tends to change the color from the original, so no
  guarantee the reproduction will be accurate against
  the original.

  ## Relative Intent

  Relative colorimetric changes all the colours out
  of gamut to the nearest colour in gamut, so many
  colours change to the same one. It DOES NOT change
  colours in gamut. Perceptual changes ALL the colours
  in the image in a proportional way so that they lie
  in the output device gamut.

  ## Saturation Intent

  Saturation moves in-gamut colors toward the edge of the
  destination gamut for maximum saturation and impact.
  This intent will make an image more colorful by using
  the full gamut of the destination device. This intent
  cares not for the genuine representation of color.

  ## Absolute Intent

  Absolute rendering attempts to reproduce all
  colors numerically (destination = source). This
  can cause unexpected results if the source gamut is
  larger than the destination.

  """
  @type render_intent :: :perceptual | :relative | :saturation | :absolute

  @typedoc """
  Error messages returned by `libvips`

  Typically a string.

  """
  @type error_message :: term()

  @typedoc """
  A pixel is represented as a list of float values.
  The number of list elements is determined by
  the colorspace interpretations. For example:

  * `RGB` colorspace would be represented by
    a list of three floats like `[0.0, 0,0, 0.0]` for black.

  * `CMYK` colorspace would be represented by a
    list of four floats.

  * A `PNG` image can be in any appropriate
    colorspace but may also have an `alpha` band
    and therefore have three, four or five floats
    in a list to represent the pixel.

  """
  @type pixel :: [float()]

  @typedoc """
  Image orientation.

  """
  @type orientation :: :landscape | :portrait | :square

  @typedoc """
  A composition is a 2-tuple defining an image
  and the options which describe how to
  compose this image on a base image.

  """
  @type composition :: {Vimage.t(), composition_options}

  @typedoc """
  When composing an image on a base image, these
  options drive how the composition proceeds.

  * `:x` describes the absolute `x` offset on the
    base image where this image will be placed. If
    this option is set to `:left`, `:center` or
    `:right` then the `x` position will be calculated
    relative to the base image. If `:x` is nil
    (the default) then the image will be placed according
    to the relative offset of the previously composed
    image using `:dx`.

  * `:y` describes the absolute `y` offset on the
    base image where this image will be placed. If
    this option is set to `:top`, `:middle` or
    `:bottom` then the `y` position will be calculated
    relative to the base image. If `:y` is nil
    (the default) then the image will be placed according
    to the relative offset of the previously composed
    image using `:dy`.

  * `:dx` describes the relative offset used to calculate
    the `x` value. `:dx` is an integer offset from the
    edge of the previously composed image. Which edge is
    determined by the `:x_baseline` option. If `:x` is also
    specified then `:x` is first calculated, then `:dx` is
    added to it. In this case, `:x_baseline` is ignored.

  * `:dy` describes the relative offset used to calculate
    the `y` value. `:dy` is an integer offset from the
    edge of the previously composed image. Which edge is
    determined by the `:y_baseline` option. If `:y` is also
    specified then `:y` is first calculated, then `:dy` is
    added to it. In this case, `:x_baseline` is ignored.

  * `:blend_mode` is the `t:Image.BlendMode.t/0` used when
    composing this image over its base image. The default
    is `:over` which is appropriate for most use cases.

  * `:x_baseline` establishes the baseline on the
    previously composed image from which `:dx` is
    calculated. The default is `:right`.

  * `:y_baseline` establishes the baseline on the
    previously composed image from which `:dy` is
    calculated. The default is `:bottom`.

  """
  @type composition_options :: [
    {:x, non_neg_integer() | nil | :left | :center | :right},
    {:y, non_neg_integer() | nil | :top | :middle | :bottom},
    {:dx, integer()},
    {:dy, integer()},
    {:blend_mode, Image.BlendMode.t()},
    {:x_baseline, :nil | :left | :center | :right},
    {:y_baseline, :nil | :top | :middle | :bottom}
  ]

  @doc """
  Guards whether the coordinates can be reasonably
  interpreted as a bounding box.

  `left` and `top` when positive are relative to
  the left and top of the image respectively. When
  negative they are relative to the right and bottom
  of the image.

  """
  defguard is_box(left, top, width, height)
           when is_integer(left) and is_integer(top) and is_integer(width) and is_integer(height) and
                  width > 0 and height > 0

  @doc """
  Guards whether a number can be reasonably interpreted
  as a size (as in size of a crop or mask)

  """
  defguard is_size(size) when is_integer(size) and size > 0

  @doc """
  Guards whether a term might be reasonably interpreted
  as an image pixel.

  """
  defguard is_pixel(value) when is_number(value) or is_list(value)

  @doc """
  Create a new image of the given dimensions and
  background color.

  ### Arguments

  * `width` is the image width as an integer.

  * `height` is the image height as an integer.

  * `options` is a keyword list of options.

  ### Options

  * `:bands` defines the number of bands (channels)
    to be created. The default is `3`.

  * `:color` defines the color of the image. This
    can be specified as a single integer which will
    be applied to all bands, or a list of
    integers representing the color for each
    band. The default is `0`, meaning black. The color
    can also be supplied as a CSS color name as a
    string or atom. For example: `:misty_rose`. See
    `Image.Color.color_map/0` and `Image.Color.rgb_color/1`.

  * `:format` defines the format of the image. The
    default is `{:u, 8}`.

  * `:interpretation` defines the interpretation of
    the image. The default is `:srgb`.

  ### Returns

  * `{:ok, image}` or

  * `{:error, reason}`

  ### Examples

        # 100x100 pixel image of dark blue slate color
        iex> {:ok, _image} = Image.new(100, 100, color: :dark_slate_blue)

        # 100x100 pixel green image, fully transparent
        iex> {:ok, _image} = Image.new(100, 100, color: [0, 255, 0, 1], bands: 4)

  """
  @spec new(width :: pos_integer(), height :: pos_integer(), options :: Options.New.t()) ::
    {:ok, Vimage.t()} | {:error, error_message()}

  def new(width, height, options \\ []) do
    with {:ok, options} <- Options.New.validate_options(options) do
      {:ok, pixel} =
        Vix.Vips.Operation.black!(1, 1, bands: options.bands)
        |> Image.Math.add!(options.color)
        |> Operation.cast(options.format)

      {:ok, image} =
        Operation.embed(pixel, 0, 0, width, height, extend: :VIPS_EXTEND_COPY)

      Operation.copy(image,
        interpretation: options.interpretation,
        xres: options.x_res,
        yres: options.y_res,
        xoffset: options.x_offset,
        yoffset: options.y_offset
      )
    end
  end

  @doc """
  Opens an image file or stream for image processing.

  ### Arguments

  * `image_path_or_stream` is the file system path to an image
    file or a `t:File.Stream.t/0` or any `t:Enumerable.t/0`.

  * `options` is a keyword list of options. The default is
    `[access: :sequential]`.

  ### Options

  The available options depend upon the image type.

  #### All image types

  * `:access` is the file access mode, either `:random`
    or `:sequential`. The default is `:sequentual`.
    When `:sequential`, `Image` (via `Vix`) is able
    to support streaming transformations and optimise
    memory usage more effectively. Howwevef `:sequenial`
    also means that some operationas cannot be completed
    because they would require non-sequential access to
    the image. In these cases, `:random` access is required.

  * `:fail_on` sets the error level at which image
    loading and decoding will stop. The default is `:none`.
    Each error state implies all the states before it such
    that `:error` implies also `:truncated`.

  #### JPEG image options

  * `:shrink` is an integer factor in the range `1..16` by
    which the image is reduced upon loading. This is an
    optimization that can result in improved performance and
    reduced memory usage if the image is being loaded
    with the intend to resize it to smaller dimensions. The
    default value is `1` meaning no shrnk-on-load.

  * `:autorotate` is a boolean value indicating if
    the image should be rotated according to the orientation
    data stored in the image metadata. The default is
    `false`.

  #### Webp options

  * `:scale` will scale the image on load. The value is
    `1..1024` with a default of `1`.

  * `:page` indicates the image page to be loaded. The
    value is in the range `0..100_000` with a default
    value of `0`.

  * `:pages` indicates how many pages to load. The value is
    in the range `1..100_000` with a default value of `1`.

  #### TIFF options

  * `:autorotate` is a boolean value indicating if
    the image should be rotated according to the orientation
    data stored in the image metadata. The default is
    `false`.

  * `:page` indicates the image page to be loaded. The
    value is in the range `0..100_000` with a default
    value of `0`.

  * `:pages` indicates how many pages to load. The value is
    in the range `1..100_000` with a default value of `1`.

  #### PNG options

  * There are no PNG-specific image loading
    options.

  ### Returns

  * `{:ok, image}` or

  * `{:error, message}`

  """
  def open(image_path_or_stream_or_binary, options \\ [])

  @spec open(image_path_or_stream :: Path.t() | File.Stream.t(), options :: Open.image_open_options()) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def open(image_path, options) when is_binary(image_path) do
    with {:ok, options} <- Options.Open.validate_options(options) do
      image_path
      |> String.split("[", parts: 2)
      |> do_open(options)
    end
  end

  def open(%File.Stream{line_or_bytes: bytes} = image_stream, options) when is_integer(bytes) do
    with {:ok, options} <- Options.Open.validate_options(options) do
      options = loader_options(options)
      Vix.Vips.Image.new_from_enum(image_stream, options)
    end
  end

  def open(%Stream{} = image_stream, options) do
    with {:ok, options} <- Options.Open.validate_options(options) do
      options = loader_options(options)
      Vix.Vips.Image.new_from_enum(image_stream, options)
    end
  end

  def open(%File.Stream{}, _options) do
    {:error,
      "File stream must be specify the number of bytes to read. " <>
      "It should be opened as File.stream!(path, options, bytes) where bytes " <>
      "is the number of bytes to read on each iteration."
    }
  end

  defp do_open([path], options) do
    if File.exists?(path) do
      options = build_option_string(options)
      Vimage.new_from_file(path <> options)
    else
      {:error, :enoent}
    end
  end

  defp do_open([path, open_options], options) do
    if File.exists?(path) do
      open_options = String.trim_trailing(open_options, "]")
      options = build_option_string(open_options, options)
      Vimage.new_from_file(path <> options)
    else
      {:error, :enoent}
    end
  end

  defp loader_options(options) do
    "[" <> Enum.map_join(options, ",", fn {k, v} -> "#{k}=#{v}" end) <> "]"
  end

  @doc """
  Returns a image created from an in-memory binary representation
  of an image.

  The binary must be a complete formatted image such as that
  returned from `File.read!/2`.

  ### Arguments

  * `binary` is a binary representation of a formatted image

  * `options` is a keyword list of options. See `Image.open/2`
    for the list of applicable options.

  ### Returns

  * `{:ok, image}` or

  * `{:error, reason}`

  """
  @doc since: "0.8.0"

  @spec from_binary(binary :: binary(), options :: Open.image_open_options()) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def from_binary(binary, options \\ []) when is_binary(binary) do
    with {:ok, options} <- Options.Open.validate_options(options) do
      options = Keyword.delete(options, :access)
      Vimage.new_from_buffer(binary, options)
    end
  end

  @doc """
  Opens an image file for image processing
  returning an image or raising an exception.

  ### Arguments

  * `image_path` is the file system path to an image
    file.

  * `options` is a keyword list of options.
    See `Image.open/2`.

  ### Returns

  * `image` or

  * raises an exception.

  """
  @spec open!(image_path :: Path.t(), options :: Options.Open.image_open_options()) ::
          Vimage.t() | no_return()

  def open!(image_path, options \\ []) do
    case open(image_path, options) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, {reason, image_path}
    end
  end

  @doc """
  Write an image to a file, a stream, and enumerable or
  to memory.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `image_path` is the file system path to an image
    file. It may also be a stream created with
    `File.stream!/3` or with `Stream.resource/3`, a
    `t:Plug.Conn.t/0` if `Plug` is configured or lastly,
    it can also be `:memory` in which case the image is
    written to a binary.

  * `options` is a keyword list of options. The default is
    `[]`.

  ### Options

  The available options depends on the type of image
  file being opened.

  ### All image types

  * `:profile` is the name of any
    [ICC color profile](https://en.wikipedia.org/wiki/ICC_profile).

  * `:strip` is a boolean indicating if all metadata
    is to be stripped from the image. The default is `false`.

  * `:background` is the background value to be used
    for any transparent areas of the image. Jpeg does
    not support alpha bands so a color value must be
    assigned.

  * `:quality` which influences image compression and
    is a integer in the range `1..100`. The default for
    most image formats is `75`. For PNG files it is the
    quantization quality with a default of `100`. For
    HEIF files the default is `50`.

  ### Streaming images and :memory images

  * `:suffix` must be specified so that the image is written
    in the correct format. For example: `suffix: ".jpg"`.

  ### JPEG images

  * `:progressive` is a boolean indicating if the image
    should be interleaved rather than baseline. Progressive
    has the advantage of perceived time for the initial
    image load and the cost of multiple decoding passes on
    the client. For many applications `:progressive` is
    to be preferred but validation of this assumption for
    specific use cases is required.

  ### PNG images

   * `:color_depth` is an integer describing the number
     of bits for each color. The value can be `1`, `2`,
     `4`, `8` or `16`.  The default is to use the current
     color depth of the image.  For web applications, `8`
     bits would be reasonable for photographic images with
     lower bit depths for monochromatic images or diagrams.

   * `:progressive` which has the same meaning and values
      as for JPEG images.

   * `:compression` is the image compression factor as an
      image between `0..9`. The default is `6`.

  ### TIFF images

  * `:color_depth` which has the same meaning as for
    PNG images.

  ### Heif images

  * `:compression` is the compression strategy to
    be applied. The allowable values are `:hevc`,
    `:avc`, `:jpeg` and `:av1`. The default is `:hevc`.

  """
  if match?({:module, _module}, Code.ensure_compiled(Plug)) do
    @spec write(
            image :: Vimage.t(),
            image_path :: Path.t() | Plug.Conn.t() | Enumerable.t() | File.Stream.t() | :memory,
            options :: Options.Write.image_write_options()
          ) ::
            {:ok, Vimage.t()} | {:error, error_message()}
  else
    @spec write(
            image :: Vimage.t(),
            image_path :: Path.t() | Enumerable.t() | File.Stream.t() | :memory,
            options :: Options.Write.image_write_options()
          ) ::
            {:ok, Vimage.t()} | {:error, error_message()}
  end

  def write(image, image_path, options \\ [])

  def write(%Vimage{} = image, image_path, options) when is_binary(image_path) do
    with {:ok, options} <- Options.Write.validate_options(options) do
      image_path
      |> String.split("[", parts: 2)
      |> write_path(image, options)
    end
  end

  if match?({:module, _module}, Code.ensure_compiled(Plug)) do
    def write(%Vimage{} = image, %Plug.Conn{} = conn, options) do
      with {:ok, options} <- Options.Write.validate_options(options, :require_suffix) do
        {suffix, options} = Keyword.pop(options, :suffix)
        options = suffix <> loader_options(options)

        image
        |> Vimage.write_to_stream(options)
        |> Enum.reduce_while(conn, fn (chunk, conn) ->
          case Plug.Conn.chunk(conn, chunk) do
            {:ok, conn} ->
              {:cont, conn}
            {:error, :closed} ->
              {:halt, conn}
          end
        end)
      end
    end
  end

  def write(%Vimage{} = image, :memory, options) do
    with {:ok, options} <- Options.Write.validate_options(options, :require_suffix) do
      {suffix, options} = Keyword.pop(options, :suffix)
      options = suffix <> loader_options(options)
      Vimage.write_to_buffer(image, options)
    end
  end

  def write(%Vimage{} = image, %module{} = stream, options) when module in [File.Stream, Stream] do
    with {:ok, options} <- Options.Write.validate_options(options, :require_suffix) do
      case write_stream(image, stream, options) do
        :ok -> {:ok, image}
        other -> other
      end
    end
  end

  defp write_stream(image, stream, options) do
    {suffix, options} = Keyword.pop(options, :suffix)
    options = suffix <> loader_options(options)

    image
    |> Vimage.write_to_stream(options)
    |> Stream.into(stream)
    |> Stream.run()
  rescue e in Vix.Vips.Image.Error->
    {:error, e.message}
  end

  defp write_path([image_path], image, options) do
    options = build_option_string(options)

    case Vimage.write_to_file(image, image_path <> options) do
      :ok -> {:ok, image}
      other -> other
    end
  end

  defp write_path([image_path, open_options], image, options) do
    write_options = String.trim_trailing(open_options, "]")
    options = build_option_string(write_options, options)

    case Vimage.write_to_file(image, image_path <> options) do
      :ok -> {:ok, image}
      other -> other
    end
  end

  @doc """
  Write an image to a file, a stream or
  to memory returning the image
  or raising an exception.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `image_path` is the file system path to an image
    file. It may also be a stream created with
    `File.stream!/3` or with `Stream.resource/3`. Lastly,
    it can also be `:memory` in which case the image is
    written to a memory buffer.

  * `options` is a keyword list of options.
    See `Image.write/2`.

  ### Returns

  * `image` or

  * raises an exception.

  """
  @spec write!(
          image :: Vimage.t(),
          image_path_or_stream :: Path.t() | Plug.Conn.t() | Enumerable.t() | File.Stream.t(),
          options :: Options.Write.image_write_options()
        ) ::
          Vimage.t() | no_return()

  def write!(%Vimage{} = image, image_path, options \\ []) do
    case write(image, image_path, options) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, {reason, image_path}
    end
  end

  @doc """
  Convert an image into an enumerable
  stream.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `options` is a keyword list of options.

  ### Options

  * `:buffer_size` is the size in bytes for
    each chunk in the stream being written.
    Some services, like AWS S3, require a minumum
    5 MiB per chunk to be delivered and this option
    can be used to satisfy that requirement.

  For additional options see `Image.write/3`.

  ### Returns

  * An `t:Enumerable.t/0` suitable for
    streaming to an external service such as
    S3, Minio or any other enumerable consumer.

  ### Example

  In this example an image is opened, resized
  and then streamed into AWS S3:

      "some/image.jpg"
      |> Image.open!()
      |> Image.resize!(200)
      |> Image.stream!(suffix: ".jpg", buffer_size: 5_242_880)
      |> ExAws.S3.upload("images", "some_object_name.jpg")
      |> ExAws.request()

  Since AWS S3 requires multipart uploads to be 5MiB per
  chunk, we specify the `:buffer_size` option to
  `Image.stream!/2`.

  """
  @spec stream!(Vimage.t(), options :: Options.Write.image_write_options()) :: Enumerable.t()
  def stream!(%Vimage{} = image, options \\ []) do
    with {:ok, options} <- Options.Write.validate_options(options, :require_suffix) do
      {suffix, options} = Keyword.pop(options, :suffix)
      {buffer_size, options} = Keyword.pop(options, :buffer_size, :unbuffered)
      options = suffix <> loader_options(options)

      stream = Vimage.write_to_stream(image, options)
      if buffer_size == :unbuffered || buffer_size == 0 do
        stream
      else
        buffer!(stream, buffer_size)
      end
    else
      {:error, reason} -> raise Image.Error, reason
    end
  end

  # Rebuffers a steram into chunks of a minimum size.
  # This is useful when streaming to AWS S3 which requires
  # a minimum 5 MiB chunk size for multi-part uploads.

  defp buffer!(stream, buffer_size) do
    chunker =
      fn bin, acc ->
        acc_size = IO.iodata_length(acc)

        if IO.iodata_length(bin) + acc_size >= buffer_size do
          size = buffer_size - acc_size
          <<chunk::binary-size(size), rest::binary>> = bin
          {:cont, IO.iodata_to_binary([chunk | acc]), [rest]}
        else
          {:cont, [bin | acc]}
        end
      end

    final =
      fn
        [] -> {:cont, []}
        acc -> {:cont, IO.iodata_to_binary(acc), []}
      end

    Stream.chunk_while(stream, [], chunker, final)
  end

  @doc """
  Compose two images together to form a new image.

  ### Arguments

  * `base_image` is any `t:Vix.Vips.Image.t/0`.

  * `overlay_image` is any `t:Vix.Vips.Image.t/0` that will
    be composed over the top of `base_image`. It can also
    be a list of `t:composition/0`s that allow for multiple
    images to be composed in a single call.

  * `options` is a keyword list of options.

  ### Options for a single overlay image

  * `:blend_mode` is the manner in which the two
    images are composited. See `t:Image.BkendMode.t/0`.
    The default is `:over` which is the most common blend
    mode.

  * `:x` is the offset (0-based) from the *left* of the `base_image`
    where the `overlay_image` will be placed. It may also be
    one of the keywords `:left`, `:right` or `:center`. The
    default is `:center`.

  * `:y` is the offset (0-based) from the *top* of the `base_image`
    where the `overlay_image` will be placed.  It may also be
    one of the keywords `:top`, `:bottom` or `:middle`. The
    default is `:middle`.

  ### Composition list options

  When `overlay_image` is an `image_list`, each entry in
  the list is either a `t:Vix.Vips.Image.t/0` or a
  `t:composition/0`. A composition supports the specification
  of how a particular image is composed onto the base image.

  * `:x` describes the absolute `x` offset on the
    base image where this image will be placed. If
    this option is set to `:left`, `:center` or
    `:right` then the `x` position will be calculated
    relative to the base image. If `:x` is nil
    (the default) then the image will be placed according
    to the relative offset of the previously composed
    image using `:dx`.

  * `:y` describes the absolute `y` offset on the
    base image where this image will be placed. If
    this option is set to `:top`, `:middle` or
    `:bottom` then the `y` position will be calculated
    relative to the base image. If `:y` is nil
    (the default) then the image will be placed according
    to the relative offset of the previously composed
    image using `:dy`.

  * `:dx` describes the relative offset used to calculate
    the `x` value. `:dx` is an integer offset from the
    edge of the previously composed image. Which edge is
    determined by the `:x_baseline` option. If `:x` is also
    specified then `:x` is first calculated, then `:dx` is
    added to it. In this case, `:x_baseline` is ignored.

  * `:dy` describes the relative offset used to calculate
    the `y` value. `:dy` is an integer offset from the
    edge of the previously composed image. Which edge is
    determined by the `:y_baseline` option. If `:y` is also
    specified then `:y` is first calculated, then `:dy` is
    added to it. In this case, `:x_baseline` is ignored.

  * `:blend_mode` is the `t:Image.BlendMode.t/0` used when
    composing this image over its base image. The default
    is `:over` which is appropriate for most use cases.

  * `:x_baseline` establishes the baseline on the
    previously composed image from which `:dx` is
    calculated. The default is `:right`.

  * `:y_baseline` establishes the baseline on the
    previously composed image from which `:dy` is
    calculated. The default is `:bottom`.

  ### Returns

  * `{:ok, composed_image}` or

  * `{:error, reason}`

  ### Examples

      # Compose images over a base image using
      # absolute coordinates from the base image
      # to place each overlay image
      #==> {:ok, image} = Image.compose(base_image, polygon, x: :middle, y: :top)
      #==> {:ok, image} = Image.compose(image, explore_new, x: 260, y: 200)
      #==> {:ok, image} = Image.compose(image, places, x: 260, y: 260)
      #==> {:ok, image} = Image.compose(image, blowout, x: 260, y: 340)
      #==> {:ok, image} = Image.compose(image, start_saving, x: 260, y: 400)

      # Compose images over a base image
      # using a composition list and coordinates
      # that are either absolute with respect to the
      # base image or relative to the previously
      # composed image
      #==> Image.compose(base_image, [
      ...>   {polygon, x: :center, y: :top},
      ...>   {explore_new, y_baseline: :top, x_baseline: :left, dx: 20, dy: 200},
      ...>   {places, dy: 10},
      ...>   {blowout, dy: 20},
      ...>   {start_saving, dy: 50}
      ...> ])

  """
  @spec compose(base_image::Vimage.t(), overlay_image::Vimage.t(), options::Keyword.t()) ::
    {:ok, Vimage.t()} | {:error, error_message()}

  def compose(base_image, overlay_image_or_images, options \\ [])

  def compose(%Vimage{} = base_image, %Vimage{} = overlay_image, options) do
    x = Keyword.get(options, :x, :center)
    y = Keyword.get(options, :y, :middle)
    blend_mode = Keyword.get(options, :blend_mode)

    with {:ok, blend_mode} <- Image.BlendMode.validate_blend_mode(blend_mode) do
      {x, y} = xy_offset(base_image, overlay_image, x, y)
      Operation.composite2(base_image, overlay_image, blend_mode, x: x, y: y)
    end
  end

  @spec compose(base_image::Vimage.t(), image_list::[Vimage.t(), ...], options::Keyword.t()) ::
    {:ok, Vimage.t()} | {:error, error_message()}

  def compose(%Vimage{} = base_image, image_list, _options) when is_list(image_list) do
    width = Image.width(base_image)
    height = Image.height(base_image)

    zipped =
      Enum.reduce_while image_list, {0, 0, width, height, []}, fn
        %Vimage{} = image, {prev_x, prev_y, prev_width, prev_height, acc} ->
          build_composition(image, prev_x, prev_y, prev_width, prev_height, acc, Map.new())

        {%Vimage{} = image, options}, {prev_x, prev_y, prev_width, prev_height, acc} ->
          build_composition(image, prev_x, prev_y, prev_width, prev_height, acc, Map.new(options))
      end

    case zipped do
      {:error, reason} ->
        {:error, reason}

      {_x, _y, _height, _width, list} ->
        {overlay_images, x_list, y_list, blend_modes} = unzip_composition(list)
        Operation.composite([base_image | overlay_images], blend_modes, x: x_list, y: y_list)
    end
  end

  defp build_composition(image, prev_x, prev_y, prev_width, prev_height, acc, options) do
    import Compose, only: [get_x: 6, get_y: 6]

    options = Map.merge(Compose.default_composit_options(), options)

    with {:ok, x} <- get_x(image, prev_x, prev_width, options.x, options.dx, options.x_baseline),
         {:ok, y} <- get_y(image, prev_y, prev_height, options.y, options.dy, options.y_baseline),
         {:ok, blend_mode} <- BlendMode.validate_blend_mode(options.blend_mode) do
      {:ok, [image, x, y, blend_mode]}
    end
    |> accumulate_compositions(image, acc)
  end

  defp unzip_composition(list) do
    Enum.reduce list, {[], [], [], []}, fn
      [image, x, y, blend_mode], {images, xs, ys, blend_modes} ->
        {[image | images], [x | xs], [y | ys], [blend_mode | blend_modes]}
    end
  end

  defp accumulate_compositions(composition, image, acc) do
    case composition do
      {:ok, composition} ->
        [_image, x, y | _rest] = composition
        {:cont, {x, y, Image.width(image), Image.height(image), [composition | acc]}}

      {:error, reason} ->
        {:halt, reason}
    end
  end

  @doc """
  Compose two images together to form a new image or
  raise an exception.

  ### Arguments

  * `base_image` is any `t:Vix.Vips.Image.t/0`.

  * `overlay_image` is any `t:Vix.Vips.Image.t/0` that will
    be composed over the top of `base_image`.

  * `options` is a keyword list of options.

  ### Options

  * `:blend_mode` is the manner in which the two
    images are composited. See `t:Image.BlendMode.t/0`.
    The default is `:over` which is the most common blend
    mode.

  * `:x` is the offset (0-based) from the *left* of the `base_image`
    where the `overlay_image` will be placed. It may also be
    one of the keywords `:left`, `:right` or `:center`. The
    default is `:center`.

  * `:y` is the offset (0-based) from the *top* of the `base_image`
    where the `overlay_image` will be placed.  It may also be
    one of the keywords `:top`, `:bottom` or `:middle`. The
    default is `:middle`.

  ### Composition list options

  When `overlay_image` is an `image_list`, each entry in
  the list is either a `t:Vix.Vips.Image.t/0` or a
  `t:composition/0`. A composition supports the specification
  of how a particular image is composed onto the base image.

  * `:x` describes the absolute `x` offset on the
    base image where this image will be placed. If
    this option is set to `:left`, `:center` or
    `:right` then the `x` position will be calculated
    relative to the base image. If `:x` is nil
    (the default) then the image will be placed according
    to the relative offset of the previously composed
    image using `:dx`.

  * `:y` describes the absolute `y` offset on the
    base image where this image will be placed. If
    this option is set to `:top`, `:middle` or
    `:bottom` then the `y` position will be calculated
    relative to the base image. If `:y` is nil
    (the default) then the image will be placed according
    to the relative offset of the previously composed
    image using `:dy`.

  * `:dx` describes the relative offset used to calculate
    the `x` value. `:dx` is an integer offset from the
    edge of the previously composed image. Which edge is
    determined by the `:x_baseline` option. If `:x` is also
    specified then `:x` is first calculated, then `:dx` is
    added to it. In this case, `:x_baseline` is ignored.

  * `:dy` describes the relative offset used to calculate
    the `y` value. `:dy` is an integer offset from the
    edge of the previously composed image. Which edge is
    determined by the `:y_baseline` option. If `:y` is also
    specified then `:y` is first calculated, then `:dy` is
    added to it. In this case, `:x_baseline` is ignored.

  * `:blend_mode` is the `t:Image.BlendMode.t/0` used when
    composing this image over its base image. The default
    is `:over` which is appropriate for most use cases.

  * `:x_baseline` establishes the baseline on the
    previously composed image from which `:dx` is
    calculated. The default is `:right`.

  * `:y_baseline` establishes the baseline on the
    previously composed image from which `:dy` is
    calculated. The default is `:bottom`.

  ### Returns

  * `composed_image` or

  * raises an exception

  ### Examples

      # Compose images over a base image using
      # absolute  coordinates from the base image
      # to place each overlay image
      #==> base_image
      ...> |> Image.compose!(polygon, x: :middle, y: :top)
      ...> |> Image.compose!(explore_new, x: 260, y: 200)
      ...> |> Image.compose!(places, x: 260, y: 260)
      ...> |> Image.compose!(blowout, x: 260, y: 340)
      ...> |> Image.compose!(start_saving, x: 260, y: 400)

      # Compose images over a base image
      # using a composition list and coordinates
      # that are either absolute with respect to the
      # base image or relative to the previously
      # composed image
      #==> base_image
      ...> |> Image.compose!([
      ...>   {polygon, x: :center, y: :top},
      ...>   {explore_new, y_baseline: :top, x_baseline: :left, dx: 20, dy: 200},
      ...>   {places, dy: 10},
      ...>   {blowout, dy: 20},
      ...>   {start_saving, dy: 50}
      ...> ])

  """
  @spec compose!(base_image::Vimage.t(), overlay_image::Vimage.t(),  options::Keyword.t()) ::
     Vimage.t() | no_return()

  def compose!(base_image, image_or_image_list, options \\ [])

  def compose!(%Vimage{} = base_image, %Vimage{} = overlay_image, options) do
    case compose(base_image, overlay_image, options) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @spec compose!(base_image::Vimage.t(), image_list::[Vimage.t(), ...],  options::Keyword.t()) ::
     Vimage.t() | no_return()

  def compose!(%Vimage{} = base_image, image_list, options) when is_list(image_list) do
    case compose(base_image, image_list, options) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Returns the filename for an image.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ### Returns

  * The pathname from which the image was opened or
    `nil` if there is no associated path. This can
    happen in the case of a streamed image or an image
    created from a memory buffer.

  """
  @spec filename(image :: Vimage.t()) :: Path.t() | nil
  def filename(%Vimage{} = image) do
    Vix.Vips.Image.filename(image)
  rescue e in RuntimeError ->
    if e.message == "null_value" do
      nil
    else
      reraise e, __STACKTRACE__
    end
  end

  @doc """
  Returns the EXIF data for an image as a
  map.

  Only a subset of EXIF data is returned but
  its a substantial subset.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`

  ### Returns

  * `{:ok, exif_map}` where `exif_map` is a map
    of selected EXIF data.

  """
  @spec exif(Vimage.t()) :: {:ok, map()}
  def exif(%Vimage{} = image) do
    with {:ok, exif_blob} <- Vimage.header_value(image, "exif-data"),
         <<"Exif"::binary, 0::16, exif::binary>> <- exif_blob do
      exif
      |> Exif.extract_exif()
      |> wrap(:ok)
    else
      false -> {:error, "Invalid Exif data"}
      other -> other
    end
  end

  @doc """
  Returns the XMP data for an image as a
  keyword list.

  Only a selected set of XMP data is returned.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`

  ### Returns

  * `{:ok, xmp_map}` where `xmp_map` is a map
    of selected XMP data.

  """
  @spec xmp(Vimage.t()) :: {:ok, map()}
  def xmp(%Vimage{} = image) do
    with {:ok, xmp_blob} <- Vimage.header_value_as_string(image, "xmp-data"),
         {:ok, xmp_binary} <- Base.decode64(xmp_blob) do
      xmp_binary
      |> SweetXml.parse(dtd: :none)
      |> Xmp.extract_xmp()
      |> wrap(:ok)
    end
  end

  @doc """
  Returns the width of an image.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`

  ### Returns

  * The image width as an integer.

  """
  @spec width(Vimage.t()) :: integer()
  def width(%Vimage{} = image) do
    Vimage.width(image)
  end

  @doc """
  Returns the height of an image.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`

  ### Returns

  * The image height as an integer.

  """
  @spec height(Vimage.t()) :: integer()
  def height(%Vimage{} = image) do
    Vimage.height(image)
  end

  @doc """
  Return the number of bands in an image.

  A band is sometimes referred to as a
  channel.

  Note than bands are 0-indexed. That is, the
  first band is band 0, the second band is
  band 1 and so on.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ### Returns

  * An integer number of bands in the image.

  """
  @spec bands(Vimage.t()) :: integer
  def bands(%Vimage{} = image) do
    Vimage.bands(image)
  end

  @doc """
  Flip an image horizontally or vertically.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `direction` is either `:horizontal` or
    `:vertical`.

  ### Returns

  * `{:ok, flipped_image}` or

  * `{:error, reason}`

  """
  @spec flip(image :: Vimage.t(), direction :: :vertical | :horizontal) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def flip(%Vimage{} = image, :vertical) do
    Operation.flip(image, :VIPS_DIRECTION_VERTICAL)
  end

  def flip(%Vimage{} = image, :horizontal) do
    Operation.flip(image, :VIPS_DIRECTION_HORIZONTAL)
  end

  def flip(%Vimage{} = _image, direction) do
    {:error,
     "Invalid flip direction. Must be :vertical or :horizontal.  Found #{inspect(direction)}"}
  end

  @doc """
  Flip an image horizontally or vertically returning
  a flipped image or raising an exception.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `direction` is either `:horizontal` or
    `:vertical`.

  ### Returns

  * `flipped_image` or

  * raises an exception.

  """
  @spec flip!(image :: Vimage.t(), direction :: :vertical | :horizontal) ::
          Vimage.t() | no_return()

  def flip!(%Vimage{} = image, direction) do
    case flip(image, direction) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Resize an image to fit or fill a bounding box.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0` or a
    pathname to an image file.

  * `width` is the integer width of the resulting
    image after resizing. It can also be of the form
    "<width>x<height>". That is, a string with the
    width and height separated by an `x`. The `<height>`
    may be omitted in which case it is the same as
    providing an integer width.

  * `options` is a keyword list of options.

  ### Options

  * `:crop` determines if the strategy is "resize to fit"
    (crop is `:none`) or "resize to fill" (when the crop
    option is not `:none`. The value may be one of
    `:none`, `:center`, `:entropy`, `:attention`, `:low`
    or `:high`. The default is `:none`. See also `t:Image.Options.Crop.crop_focus/0`.

  * `:autorotate` is a boolean indicating if the image should
    be autorated based upon the image metadata. The default
    is `true`.

  * `:intent` indicates the rendering intent. The default
    is `:relative`. See also `t:Image.render_intent/0`.

  * `:export_icc_profile` -Indicates the icc profile to be attached
    to the resized image. The value may be an inbuilt profile (`:srgb`,
    `:p3` or `:cmyk`), the name of an icc profile in the systems
    profile directory or a full path to an icc profile file. The
    default is to export the icc profile of the resized image if
    there is one.

  * `:import_icc_profile` -Indicates the icc profile to be attached
    to the input image. The value may be an inbuilt profile (`:srgb`,
    `:p3` or `:cmyk`), the name of an icc profile in the systems
    profile directory or a full path to an icc profile file. The
    default is to use the icc profile of the input image if
    there is one.

  * `:linear` is a boolean indicating of the image should
    be resized in linear space. The default `false`. Shrinking is
    normally done in sRGB colourspace. Set linear to shrink in
    linear light colourspace instead. This can give better results,
    but can also be far slower, since tricks like JPEG shrink-on-load
    cannot be used in linear space.

  * `:resize` determines if an image may be only upsized, only
    downsized, or both. The value may be one of `:up`, `:down`,
    `:both` or `:force`. The default is `:both`.

  * `:height` - Size to this height. Default is to maintain
    the image aspect ratio unless `resize: :force` is set.

  ### Returns

  * `{:ok, resized_image}` or

  * `{:error, reason}`

  """
  @spec resize(Vimage.t(), width :: pos_integer() | binary(), options :: Resize.resize_options()) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def resize(image_or_path, width, options \\ [])

  def resize(%Vimage{} = image, width, options) when is_size(width) do
    with {:ok, options} <- Resize.validate_options(options) do
      Operation.thumbnail_image(image, width, options)
    end
  end

  @spec resize(Path.t(), width :: pos_integer(), options :: Resize.resize_options()) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def resize(image_path, width, options) when is_binary(image_path) and is_size(width) do
    with {:ok, options} <- Resize.validate_options(options),
         {:ok, _file} = file_exists?(image_path) do
      Operation.thumbnail(image_path, width, options)
    end
  end

  @spec resize(Vimage.t() | Path.t(), dimensions :: binary(), options :: Resize.resize_options()) ::
    {:ok, Vimage.t()} | {:error, error_message()}

  def resize(image_or_path, dimensions, options) when is_binary(dimensions) do
    with {:ok, width, options} <- Resize.validate_dimensions(dimensions, options) do
      resize(image_or_path, width, options)
    end
  end

  @doc """
  Resize an image to fit or fill a bounding box
  returning an image or raising an exception.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0` or a
    pathname to an image file.

  * `width` is the integer width of the resulting
    image after resizing. It can also be of the form
    "<width>x<height>". That is, a string with the
    width and height separated by an `x`. The `<height>`
    may be omitted in which case it is the same as
    providing an integer width.

  * `options` is a keyword list of options.
    See `Image.resize/3`.

  ### Returns

  * `image` or

  * raises an exception.

  """
  @spec resize!(
          Vimage.t() | Path.t(),
          width_or_dimensions :: pos_integer() | binary(),
          options :: Options.Resize.resize_options()
        ) ::
          Vimage.t() | no_return

  def resize!(%Vimage{} = image, width_or_dimensions, options \\ []) do
    case resize(image, width_or_dimensions, options) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Make a circular image intended to be used
  as an avatar image.

  The image is resized, a circular mask is
  applied and all metadata is removed from
  the image.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `size` is the diameter of the resulting
    image after resizing. The default value
    is `#{@default_avatar_size}`.

  * `options` is a keyword list of options.
    See `Image.resize/3` for the valid options.

  ### Returns

  * `{:ok, avatar_image}` or

  * `{:error, reason}`

  """

  @spec avatar(Vimage.t(), size :: pos_integer(), options :: Options.Avatar.avatar_options()) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def avatar(image, size \\ @default_avatar_size, options \\ [])

  def avatar(%Vimage{} = image, size, options) when is_size(size) do
    with {:ok, options} <- Options.Avatar.validate_options(options) do
      {:ok, image} = Operation.thumbnail_image(image, size, options)
      circular_mask_and_remove_meta(image)
    end
  end

  def avatar(image_path, size, options) when is_binary(image_path) and is_size(size) do
    with {:ok, options} <- Options.Avatar.validate_options(options),
         {:ok, image_path} = file_exists?(image_path) do
      {:ok, image} = Operation.thumbnail(image_path, size, options)
      circular_mask_and_remove_meta(image)
    end
  end

  defp circular_mask_and_remove_meta(image) do
    {:ok, image} = circle(image)
    remove_metadata(image)
  end

  @doc """
  Make a circular image intended to be used
  as an avatar image returning an image or
  raising an exception.

  The image is resized, a circular mask is
  applied and all metadata is removed from
  the image.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `size` is the diameter of the resulting
    image after resizing. The default value
    is `#{@default_avatar_size}`.

  * `options` is a keyword list of options.
    See `Image.resize/3` for the valid options.

  ### Returns

  * `avatar_image` or

  * raises an exception.

  """

  @spec avatar!(Vimage.t(), size :: pos_integer(), options :: Options.Avatar.avatar_options()) ::
          Vimage.t() | no_return()

  def avatar!(%Vimage{} = image, size \\ @default_avatar_size, options \\ []) do
    case avatar(image, size, options) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Crop an image.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `left` is the top edge of crop area as an
    integer. If `left` is positive it is relative to
    the left edge of the image. If it is negative it is
    relative to the right edge of the image.

  * `top` is the top edge of crop area as an
    integer. If `top` is positive it is relative to
    the top edge of the image. If it is negative it is
    relative to the bottom edge of the image.

  * `width` is the width of area remaining as a
    positive integer.

  * `height` is the height of the area remaining
    as a positive integer.

  ### Notes

  * `left` is 0-indexed. That is, the leftmost
    edge of the image starts at `0`.

  * `top` is 0-indexed. That is, the toptmost
    edge of the image starts at `0`.

  ### Returns

  * `{:ok, cropped_image}` or

  * `{:error, reason}`

  """
  @spec crop(Vimage.t(), integer(), integer(), pos_integer(), pos_integer()) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def crop(%Vimage{} = image, left, top, width, height)
      when is_box(left, top, width, height) and left >= 0 and top >= 0 do
    Operation.extract_area(image, left, top, width, height)
  end

  def crop(%Vimage{} = image, left, top, width, height)
      when is_box(left, top, width, height) and left < 0 and top >= 0 do
    left = width(image) + left - width
    Operation.extract_area(image, left, top, width, height)
  end

  def crop(%Vimage{} = image, left, top, width, height)
      when is_box(left, top, width, height) and left >= 0 and top < 0 do
    top = height(image) + top - height
    Operation.extract_area(image, left, top, width, height)
  end

  def crop(%Vimage{} = image, left, top, width, height)
      when is_box(left, top, width, height) and left < 0 and top < 0 do
    left = width(image) + left - width
    top = height(image) + top - height
    Operation.extract_area(image, left, top, width, height)
  end

  @doc """
  Crop an image returning a cropped image
  or raising an exception.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `left` is the left edge of extract area as a
    positive integer.

  * `top` is the top edge of extract area as an
    integer. If `top` is positive it is relative to
    the top of the image. If it is negative it is
    relative to the bottom of the image.

  * `width` is the width of extract area as a
    positive integer.

  * `height` is the height of extract area as a
    positive integer.

  ### Returns

  * `cropped_image` or

  * raises an exception.

  """
  @spec crop!(Vimage.t(), integer(), integer(), pos_integer(), pos_integer()) ::
          Vimage.t() | no_return

  def crop!(%Vimage{} = image, left, top, width, height) do
    case crop(image, left, top, width, height) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Rotate an image clockwise (to the
  right) by a number of degrees.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `angle` is a `float` number of degrees
    to rotate in a clockwise direction.

  * `options` is a keyword list of options.

  ### Options

  * `:idy` is the vertical input displacement which
    defaults to `0.0`

  * `:idx` is the horizontal input displacement which
    defaults to `0.0`

  * `:ody` is the vertical output displacement
    which defaults to `0.0`

  * `:odx` is the horizontal output displacement
    which defaults to `0.0`

  * `:background` is the background color to be used for filling
    the blank areas of the image. The background is specified as
    a list of 3 or 4 float values depending on the image
    color space.

  ## Notes

  The displacement parameters cause the image canvas to be
  expanded and the image displaced, relative to the top left
  corner of the image, by the amount specified.

  The rules defining how the image canvas is expanded
  is not known to the author of `Image`. Experimentation will
  be required if you explore these options.

  ### Returns

  * `{:ok, rotated_image}` or

  * `{:error, reason}`

  """
  @spec rotate(
          image :: Vimage.t(),
          angle :: float(),
          options :: Options.Rotate.rotation_options()
        ) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def rotate(%Vimage{} = image, angle, options \\ []) when is_number(angle) do
    with {:ok, options} <- Options.Rotate.validate_options(options) do
      Operation.rotate(image, angle, options)
    end
  end

  @doc """
  Rotate an image clockwise (to the
  right) by a number of degrees.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `angle` is a `float` number of degrees
    to rotate in a clockwise direction.

  * `options` is a keyword list of options.
    See `Image.rotate/3`.

  ## Notes

  The displacement parameters cause the image canvas to be
  expanded and the image displaced, relative to the top left
  corner of the image, by the amount specified.

  The rules defining how the image canvas is expanded
  is not known to the author of `Image`. Experimentation will
  be required if you explore these options.

  ### Returns

  * `rotated_image` or

  * raises an exception.

  """
  @spec rotate!(
          image :: Vimage.t(),
          angle :: float(),
          options :: Options.Rotate.rotation_options()
        ) ::
          Vimage.t() | no_return()

  def rotate!(%Vimage{} = image, angle, options \\ []) when is_number(angle) do
    case rotate(image, angle, options) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Rotate an image based upon the orientation
  information in an image's EXIF data.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ### Returns

  * `{:ok, {auto_rotated_image, flags}}` or

  * `{:error, reason}`

  ### Flags

  Two flags are returned indicating what action
  was taken:

  * `:flip` which is a boolean indicating if the image
    was flipped or not and

  * `:angle` through which the image was rotated.
    This value will be one of `0`, `90`, `180` or
    `270` representing the degrees of rotation.

  """
  @spec autorotate(image :: Vimage.t()) ::
          {:ok, {Vimage.t(), Keyword.t()}} | {:error, error_message()}

  def autorotate(%Vimage{} = image) do
    case Operation.autorot(image) do
      {:ok, {image, flags}} ->
        {:ok, {image, decode_rotation_flags(flags)}}

      other ->
        other
    end
  end

  @rotation_encoding %{
    VIPS_ANGLE_D0: 0,
    VIPS_ANGLE_D90: 90,
    VIPS_ANGLE_D180: 180,
    VIPS_ANGLE_D270: 270
  }

  defp decode_rotation_flags(flags) do
    angle = Keyword.fetch!(flags, :angle)
    angle = Map.fetch!(@rotation_encoding, angle)

    Keyword.put(flags, :angle, angle)
  end

  @doc """
  Rotate an image based upon the orientation
  information in an image's EXIF data. Returns
  a potentially rotated image or raises and
  exception.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ### Returns

  * `auto_rotated_image` or

  * raises an exception.

  """
  @spec autorotate!(image :: Vimage.t()) ::
          Vimage.t() | no_return()

  def autorotate!(image) do
    case autorotate(image) do
      {:ok, {image, _flags}} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Adds a concentric ripple effect to an image.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ### Returns

  * `{:ok, image_with_ripple}` or

  * `{:error, reason}`

  """
  @spec ripple(Vimage.t()) :: {:ok, Vimage.t()} | {:error, error_message()}
  def ripple(%Vimage{} = image) do
    use Image.Math

    width = width(image)
    height = height(image)

    # this makes an image where pixel (0, 0) (at the top-left) has value [0, 0],
    # and pixel (image.width, image.height) at the bottom-right has value
    # [image.width, image.height]
    {:ok, index} = Operation.xyz(width, height)

    # make a version with (0, 0) at the centre, negative values up and left,
    # positive down and right
    center = index - [width / 2, height / 2]

    # to polar space, so each pixel is now distance and angle in degrees
    {:ok, polar} = Complex.polar(center)

    # scale sin(distance) by 1/distance to make a wavey pattern
    d = 10_000 * sin!(polar[0] * 3) / (1 + polar[0])

    # and back to rectangular coordinates again to make a set of vectors we can
    # apply to the original index image
    {:ok, joined} = Operation.bandjoin([d, polar[1]])
    {:ok, rectangular} = Complex.rectangular(joined)
    index = index + rectangular

    # finally, use our modified index image to distort the input!
    Operation.mapim(image, index)
  end

  @doc """
  Adds a concentric ripple effect to an image
  returning an image or raising an exception.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ### Returns

  * `image_with_ripple` or

  * raises an exception.

  """
  @spec ripple!(Vimage.t()) :: Vimage.t() | no_return()
  def ripple!(%Vimage{} = image) do
    case ripple(image) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Apply a circular mask to an image.

  The returned image has an alpha
  band masking the circular image.

  As a result, it is best saved to a
  format, like `.png` that supports
  alpha transparency.

  Note that `.jpg` files do not support
  alpha transparency.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ### Returns

  * `{:ok, circular_image}` or

  * `{:error, reason}`

  """
  @spec circle(Vimage.t(), Keyword.t()) :: {:ok, Vimage.t()} | {:error, error_message()}
  def circle(%Vimage{} = image, _options \\ []) do
    width = width(image)
    height = height(image)
    size = min(width, height)

    {:ok, mask} = mask(:circle, size, size)
    Operation.bandjoin([image, mask])
  end

  @doc """
  Apply a circular mask to an image
  returning an image or raising an
  exception.

  The returned image has an alpha
  band masking the circular image.

  As a result, it is best saved to a
  format, like `.png` that supports
  alpha transparency.

  Note that `.jpg` files do not support
  alpha transparency.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ### Returns

  * `circular_image` or

  * raises an exception.

  """
  @spec circle!(Vimage.t(), Keyword.t()) :: Vimage.t() | no_return()
  def circle!(%Vimage{} = image, options \\ []) do
    case circle(image, options) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Apply rounded corners to an image.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `options` is a keyword list of options.

  ### Options

  * `:radius` is the desired corner radius.
    The default is #{@default_round_corner_radius}.

  ### Returns

  * `{:ok, rounded_corner_image}` or

  * `{:error, reason}`

  """
  @spec rounded(Vimage.t(), Keyword.t()) :: {:ok, Vimage.t()} | {:error, error_message()}
  def rounded(%Vimage{} = image, options \\ []) do
    options = Keyword.put_new(options, :radius, @default_round_corner_radius)
    width = width(image)
    height = height(image)

    {:ok, mask} = mask(:rounded_corners, width, height, options)
    Operation.bandjoin([image, mask])
  end

  @doc """
  Apply rounded corners to an image. Returns
  an image or raises an exception.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `options` is a keyword list of options.

  ### Options

  * `:radius` is the desired corner radius.
    The default is #{@default_round_corner_radius}.

  ### Returns

  * `rounded_corner_image` or

  * raises an exception.

  """
  @spec rounded!(Vimage.t(), Keyword.t()) :: Vimage.t() | no_return()
  def rounded!(%Vimage{} = image, options \\ []) do
    case rounded(image, options) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  # Create an image mask (alpha transparency) that can
  # then be applied to an image.

  # At some point this will become a public API.

  defp mask(type, width, height, options \\ [])

  defp mask(:circle, diameter, diameter, _options) do
    centre = div(diameter, 2)

    svg = """
    <svg viewBox="0 0 #{diameter} #{diameter}">
      <circle style="fill: black; stroke: none" cx="#{centre}" cy="#{centre}" r="#{centre}"/>
    </svg>
    """

    {:ok, {circle, _flags}} = Operation.svgload_buffer(svg)
    Operation.extract_band(circle, alpha_band(circle))
  end

  defp mask(:rounded_corners, width, height, options) do
    radius = Keyword.get(options, :radius, @default_round_corner_radius)

    svg = """
    <svg viewBox="0 0 #{width} #{height}">
      <rect rx="#{radius}" ry="#{radius}" x="0" y="0" width="#{width}" height="#{height}" fill="black" />
    </svg>
    """

    {:ok, {mask, _flags}} = Operation.svgload_buffer(svg)
    Operation.extract_band(mask, alpha_band(mask))
  end

  @doc """
  Minimize metadata by keeping only the artist
  and copyright (if available).

  Removing metadata from an image can greatly reduce
  the overall size of an image. The proprtional
  reduction is most noticeable with smaller images
  which are very common in web applications.

  Removing all metadata is a common option however
  with intellectual property concerns in mind
  this function will keep the artist and
  copyright fields if they exist in the original
  image.

  On a 1000x500px image exported from Adobe Lightroom
  with metadata intact, removing the metadata
  results in am approximately 50% saving in file
  size due to the removal of most EXIF and all
  IPTC and XMP metadata.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`

  ### Returns

  * `{:ok, image_with_minimal_metadata}` or

  * `{:error, reason}`

  """
  @spec minimize_metadata(image :: Vimage.t()) :: {:ok, Vimage.t()} | {:error, error_message()}
  def minimize_metadata(%Vimage{} = image) do
    with {:ok, _exif} <- exif(image),
         {:ok, image} <- remove_metadata(image) do
      {:ok, artist} = Exif.get_metadata(image, :artist)
      {:ok, copyright} = Exif.get_metadata(image, :copyright)

      Vimage.mutate(image, fn mut_img ->
        :ok = MutableImage.set(mut_img, "exif-data", :VipsBlob, <<0>>)

        Exif.put_metadata(mut_img, :copyright, copyright)
        Exif.put_metadata(mut_img, :artist, artist)
      end)
    end
  end

  @doc """
  Minimize metadata by keeping only the artist
  and copyright (if available).

  See also `Image.minimize_metadata/1`.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`

  ### Returns

  * ` image_with_minimal_metadata` or

  * raises an exception.

  """
  @spec minimize_metadata!(image :: Vimage.t()) :: Vimage.t() | no_return()
  def minimize_metadata!(%Vimage{} = image) do
    case minimize_metadata(image) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @metadata_fields %{
    exif: "exif-data",
    xmp: "xmp-dataa",
    iptc: "iptc-data"
  }

  @metadata_names Map.keys(@metadata_fields)

  @doc """
  Remove metadata from an image returning
  an updated image or raising an exception.

  This can significantly reduce the size of
  an image file.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`

  * `fields` is a list of metadata field names
    as strings. The default is all known
    field names. There are some special field
    names interpreted by `Image` to simplify
    metadata removal these are:

    * `:exif` which means remove all
      [EXIF](https://en.wikipedia.org/wiki/Exif) metadata
    * `:iptc` which means remove all
      [IPTC](https://en.wikipedia.org/wiki/IPTC_Information_Interchange_Model) metadata
    * `:xmp` which means remove all
      [xmp](https://en.wikipedia.org/wiki/Extensible_Metadata_Platform) data

  ## Notes

  * The available field names (ie. metadata fields)
    in an image can be returned with a call to
    `Vix.Vips.Image.header_field_names/1`.

  * Errors removing metadata fields is not propagated
    into the return for this function. Errors might occur
    when attempting to remove metadata fields that
    do not exist in the image.

  ### Returns

    * `{:ok, image_without_metadata_fields}` or

    * `{:error, reason}`

  """
  @spec remove_metadata(Vimage.t(), list(binary() | atom())) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def remove_metadata(image, fields \\ [])

  def remove_metadata(image, field) when not is_list(field) do
    remove_metadata(image, List.wrap(field))
  end

  def remove_metadata(image, []) do
    {:ok, fields} = Vimage.header_field_names(image)
    remove_metadata(image, fields)
  end

  def remove_metadata(%Vimage{} = image, fields) when is_list(fields) do
    Vimage.mutate(image, fn mut_img ->
      Enum.each(fields, &remove_meta(mut_img, &1))
    end)
  end

  defp remove_meta(image, field) when is_atom(field) and field in @metadata_names do
    field = Map.fetch!(@metadata_fields, field)
    remove_meta(image, field)
  end

  defp remove_meta(image, field) do
    MutableImage.remove(image, field)
  end

  @doc """
  Remove metadata from an image returning
  an image or raising an exception.

  This can significant;y reduce the size of
  an image file.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`

  * `fields` is a list of metadata field names
    as strings. The default is all known
    field names. There are some special field
    names interpreted by `Image` to simplify
    metadata removal these are:

    * `:exif` which means remove all
      [EXIF](https://en.wikipedia.org/wiki/Exif) metadata
    * `:iptc` which means remove all
      [IPTC](https://en.wikipedia.org/wiki/IPTC_Information_Interchange_Model) metadata
    * `:xmp` which means remove all
      [xmp](https://en.wikipedia.org/wiki/Extensible_Metadata_Platform) data

  ## Notes

  * The available field names (ie. metadata fields)
    in an image can be returned with a call to
    `Vix.Vips.Image.header_field_names/1`.

  * Errors removing metadata fields is not propagated
    into the return for this function. Errors might occur
    when attempting to remove metadata fields that
    do not exist in the image.

  ### Returns

    * `image_without_metadata_fields` or

    * raises an exception.

  """
  @spec remove_metadata!(Vimage.t(), list(binary() | atom())) :: Vimage.t() | no_return()
  def remove_metadata!(image, fields \\ []) do
    case remove_metadata(image, fields) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @y_band 1

  @doc """
  Create an image gradient of the same size as
  the given image.

  The gradient will interpolate from the `start`
  value to the `finish` value. The default `start`
  value is black with 100% transparency. The
  default `finish` value is black with 100% opacity.

  `start` and `finish` are given as an `rgb` triplet
  or quadruplet list of integers between `0` and `255`.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`

  * `:start is an `rgb` triplet or quadruplet
    list of numbers between `0` and `255`.

  * `:finish is an `rgb` triplet or quadruplet
    list of numbers between `0` and `255`.

  ### Returns

  * `{:ok, gradient_image}` or

  * `{:error, reason}`

  ### Example

      # transparent_black and opaque_black are the default
      # start and finish values
      transparent_black = [0, 0, 0, 0]
      opaque_black = [0, 0, 0, 255]
      {:ok, gradient} = Image.linear_gradient(image, transparent_black, opaque_black)

  """
  @start_color [0, 0, 0, 0]
  @finish_color [0, 0, 0, 255]

  @spec linear_gradient(Vimage.t(), start :: Color.rgb_color(), finish :: Color.rgb_color()) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def linear_gradient(%Vimage{} = image, start \\ @start_color, finish \\ @finish_color) do
    use Image.Math

    width = width(image)
    height = height(image)

    {:ok, xyz} = Operation.xyz(width, height)
    {:ok, y} = Operation.extract_band(xyz, @y_band)

    # the distance image: 0 - 1 for the start to the end of the gradient
    d = y / height

    # and use it to fade the quads ... we need to tag the result as an RGB
    # image
    (d * finish + (1 - d) * start)
    |> Operation.copy(interpretation: :VIPS_INTERPRETATION_sRGB)
  end

  @doc """
  Create an image gradient of the same size as
  the given image. Returns the gradient image
  or raises and exception.

  The gradient will interpolate from the `start`
  value to the `finish` value. The default `start`
  value is black with 100% transparency. The
  default `finish` value is black with 100% opacity.

  `start` and `finish` are given as an `rgb` triplet
  or quadruplet list of integers between `0` and `255`.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`

  * `:start is an `rgb` triplet or quadruplet
    list of numbers between `0` and `255`.

  * `:finish is an `rgb` triplet or quadruplet
    list of numbers between `0` and `255`.

  ### Returns

  * `gradient_image` or

  * raises an exception.

  ### Example

      # transparent_black and opaque_black are the default
      # start and finish values
      transparent_black = [0, 0, 0, 0]
      opaque_black = [0, 0, 0, 255]
      gradient = Image.linear_gradient!(image, transparent_black, opaque_black)

  """
  @spec linear_gradient!(Vimage.t(), start :: Color.rgb_color(), finish :: Color.rgb_color()) ::
          Vimage.t() | no_return()

  def linear_gradient!(%Vimage{} = image, start \\ @start_color, finish \\ @finish_color) do
    case linear_gradient(image, start, finish) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Returns a radial gradient as an image.

  This image might then be composited over
  another image.

  ### Arguments

  * `width` is the width of the gradient in
    pixels.

  * `height` is the height of the gradient in
    pixels.

  * `options` is a keyword list of options. The
    default is `[]`.

  ### Options

  * `:start` is the color from which the gradient
    starts in the center of the image.

  * `:finish` is the color at which the gradient
    finishes at the end of the gradient.

  * `:feather` is the slope of the gradient. That it,
    how quickly the gradient moves from the `:start`
    color to the `:finish` color. The valid range is
    `1..10` representing the smallest amount of feather
    (harshest transition) to the largest amount of
    feather (smoothest transition).

  ### Returns

  * `{:ok, gradient_image}` or

  * `{:error, reason}`

  """
  @doc since: "0.6.0"

  @spec radial_gradient(width :: pos_integer(), height :: pos_integer(), options :: Keyword.t()) ::
    {:ok, %Vimage{}} | {:error, error_message()}

  def radial_gradient(width, height, options \\ []) do
    use Image.Math

    # Lab colors, not RGB
    # Since rgba 0 for transparency means
    # transparent, and 1 means opaque we
    # transition from black to white
    start = [0, 0, 0]
    finish = [100, 0, 0]

    max = max(width, height)

    # Take a number 1..10
    feather = Keyword.get(options, :feather, 1)

    # Range of 0.5 to 3 -> probably linear
    radius = Keyword.get(options, :radius, 2)

    x =  Operation.xyz!(width, height) - [width / 2, height / 2]

    d = (((x[0] ** 2) + (x[1] ** 2)) ** 0.5) / (2 ** (feather * 0.05) * max / radius)
    out = (d * finish) + ((d * -1 + 1) * start)

    Operation.copy(out, interpretation: :VIPS_INTERPRETATION_LAB)
  end

  @doc """
  Returns the dominant color of an image
  as an RBG triplet value in an integer
  list.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `options` is a keyword list of options.
    The default is `[]`.

  ### Options

  * `:bins` is an integer number of color
   frequency bins the image is divided into.
   The default is `10`.

  ### Returns

  * `[r, g, b]`

  """
  @max_band_value 256

  @doc since: "0.3.0"

  @spec dominant_color(Vimage.t(), Keyword.t()) :: Color.rgb_color()
  def dominant_color(%Vimage{} = image, options \\ []) do
    bins = Keyword.get(options, :bins, 10)
    bin_size = @max_band_value / bins
    midpoint = bin_size / 2

    {:ok, histogram} = Operation.hist_find_ndim(image, bins: bins)
    {v, x, y} = Image.Math.maxpos(histogram)
    {:ok, pixel} = Operation.getpoint(histogram, x, y)
    z = Enum.find_index(pixel, &(&1 == v))

    r = (x * bin_size) + midpoint
    g = (y * bin_size) + midpoint
    b = (z * bin_size) + midpoint

    [trunc(r), trunc(g), trunc(b)]
  end

  @doc """
  Returns the histogram for an image.

  The histogram is returned as a `t:Vimage.t/0`
  that is a 255 by 255 image with three bands.

  ### Argument

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ### Returns

  * `{:ok, histogram_image}` or

  * `{:error, reason}`

  ### Notes

  The returned image is is organized
  as a 256x256 pixel image with
  the same number of bands as the original
  image.

  Each pixel on the image returns the count
  of pixels in the original image that are
  in that 1/256th part of the image.

  """
  @doc since: "0.3.0"

  @spec histogram(Vimage.t()) :: {:ok, Vimage.t()} | {:error, error_message()}
  def histogram(%Vimage{} = image) do
    image
    |> Operation.hist_find!()
    |> Operation.hist_norm!()
  end

  @doc """
  Returns the pixel value at the given image location.

  The returned pixel is a list of numbers where
  the length of the list is equal to the number
  of bands in the image.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  * `x` is an integer offset from the top
    left of the image along the `x` (width) axis.
    The number must be in the range `0..width - 1`.

  * `y` is an integer offset from the top
    left of the image along the `y` (height) axis.
    The number must be in the range `0..height - 1`.

  ### Returns

  * `{:ok, pixel_value}` or

  * `{:error, reason}`

  """
  @doc since: "0.3.0"

  @spec get_pixel(Vimage.t(), non_neg_integer(), non_neg_integer()) ::
      {:ok, Color.rgb_color()} | {:error, error_message()}

  def get_pixel(%Vimage{} = image, x, y) do
    Operation.getpoint(image, x, y)
  end

  @doc """
  Mutate an image with through the given
  function.

  This funcation is a convenience wrapper
  around `Vix.Vips.Image.mutate/2`.

  """
  @doc since: "0.7.0"

  @spec mutate(Vimage.t(), (Vix.Vips.MutableImage.t() -> any())) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def mutate(%Vimage{} = image, fun) when is_function(fun, 1) do
    Vimage.mutate(image, fun)
  end

  @doc """
  Converts an image to the given colorspace.

  Available colorspaces are returned from
  `Image.Interpretation.known_interpretations/0`.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`

  * `colorspace` is any known colorspace. See
    `Image.Interpretation.known_interpretations/0`
    for a list of the known colorspaces.

  ### Returns

  * `{;ok, image_in_new_colorspace}` or

  * `{:error, reason}`

  ### Example

      Image.to_colorspace(image, :bw)

  """
  @spec to_colorspace(Vimage.t(), Interpretation.t()) ::
          {:ok, Vimage.t()} | {:error, error_message()}

  def to_colorspace(%Vimage{} = image, colorspace) do
    with {:ok, colorspace} <- Interpretation.validate_interpretation(colorspace) do
      Vix.Vips.Operation.colourspace(image, colorspace)
    end
  end

  @doc """
  Converts an impage to the given colorspace returning
  an image or raising an exception.

  Available colorspaces are returned from
  `Image.Interpretation.known_interpretations/0`.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`

  * `colorspace` is any known colorspace. See
    `Image.Interpretation.known_interpretations/0`
    for a list of the known colorspaces.

  ### Returns

  * `image_in_new_colorspace` or

  * raises an exception

  ### Example

      Image.to_colorspace!(image, :bw)

  """
  @spec to_colorspace!(Vimage.t(), Interpretation.t()) ::
          Vimage.t() | no_return()

  def to_colorspace!(%Vimage{} = image, colorspace) do
    case to_colorspace(image, colorspace) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Convert image to polar coordinates.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ### Returns

  * `{:ok, image_in_polar_coordinates}` or

  * `{:error, reason}`

  """
  @spec to_polar_coordinates!(Vimage.t()) :: {:ok, Vimage.t()} | {:error, error_message()}
  def to_polar_coordinates(%Vimage{} = image) do
    use Image.Math

    width = width(image)
    height = height(image)

    xy = Operation.xyz!(width, height)
    xy = xy - [width / 2.0, height / 2.0]

    scale = min(width, height) / width
    xy = xy * 2.0 / scale

    {:ok, index} = Complex.polar(xy)
    index = index * [1.0, height / 360.0]

    Operation.mapim(image, index)
  end

  @doc """
  Convert image to polar coordinates returning
  an image or raising an exception.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ### Returns

  * `image_in_polar_coordinates` or

  * raises an exception.

  """
  @spec to_polar_coordinates!(Vimage.t()) :: Vimage.t() | no_return()
  def to_polar_coordinates!(%Vimage{} = image) do
    case to_polar_coordinates(image) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Convert image to rectangular coordinates.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ## Notes

  Roundtrip to polar and back to rectangular
  coordinates displays some image distortion,
  likely due to rounding errors in float
  arithmetic. Further study is required.

  ### Returns

  * `{:ok, image_in_rectangular_coordinates}` or

  * `{:error, reason}`

  """
  @spec to_rectangular_coordinates(Vimage.t()) :: {:ok, Vimage.t()} | {:error, error_message()}
  def to_rectangular_coordinates(%Vimage{} = image) do
    use Image.Math

    width = width(image)
    height = height(image)

    xy = Operation.xyz!(width, height)
    xy = xy * [1.0, 360.0 / height]

    {:ok, index} = Complex.rectangular(xy)
    scale = min(width, height) / width

    index = index * scale / 2.0
    index = index + [width / 2.0, height / 2.0]

    Operation.mapim(image, index)
  end

  @doc """
  Convert image to rectangular coordinates
  returning an image or raising an exception.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ## Notes

  Roundtrip to polar and back to rectangular
  coordinates displays some image distortion,
  likely due to rounding errors in float
  arithmetic. Further study is required.

  ### Returns

  * `image_in_rectuangular_coordinates` or

  * raises an exception.

  """
  @spec to_rectangular_coordinates!(Vimage.t()) :: Vimage.t() | no_return()
  def to_rectangular_coordinates!(%Vimage{} = image) do
    case to_rectangular_coordinates(image) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  if match?({:module, _module}, Code.ensure_compiled(Nx)) do
    @doc """
    Converts an image into an [Nx](https://github.com/packages/nx)
    tensor.

    ### Arguments

    * `image` is any `t:Vimage.t/0`

    ### Returns

    * An `t:Nx.Tensor.t/0` tensor suitable for use in
      the `Nx` library.

    ### Example

        iex> {:ok, image} = Vix.Vips.Operation.black(3, 3)
        iex> Image.to_nx(image)
        {:ok,
          Nx.tensor([[[0], [0], [0]], [[0], [0], [0]], [[0], [0], [0]]], type: {:u, 8}, names: [:width, :height, :bands])}

    """
    @doc since: "0.5.0"

    @spec to_nx(image :: Vimage.t(), options: Keyword.t()) ::
      {:ok, Nx.Tensor.t()} | {:error, error_message()}

    def to_nx(%Vimage{} = image, options \\ []) do
      {:ok, tensor} = Vix.Vips.Image.write_to_tensor(image)
      %Vix.Tensor{data: binary, names: names, shape: shape, type: type} = tensor

      binary
      |> Nx.from_binary(type, options)
      |> Nx.reshape(shape, names: names)
      |> wrap(:ok)
    end

    @doc """
    Converts an [Nx](https://github.com/packages/nx) tensor
    into an image.

    ### Arguments

    * `tensor` is any three dimensional `t:Nx.Tensor.t/0`.

    * `options` is a keyword list of options. For valid
      options see `Nx.from_binary/2`.

    ### Returns

    * `{:ok, image}` or

    * `{:error, reason}`

    ### Notes

    In order to convert a tensor into an image it must
    satisfy these constraints:

    * It must have three dimensions.

    * It must have a tensor type that is compatible
      with `libvips` (most tensors will satisfy this
      requirement other than tensors whose type is complex).

    * The names of the axes must be `[:width, :height, any_other]`
      or `[:height, :width, any_other]`.

    ### Example

        iex> {:ok, image} = Vix.Vips.Operation.black(3, 3)
        iex> {:ok, tensor} = Image.to_nx(image)
        iex> {:ok, _image_2} = Image.from_nx(tensor)

    """
    @doc since: "0.5.0"

    @spec from_nx(tensor :: Nx.Tensor.t()) ::  {:ok, Vimage.t()} | {:error, error_message()}
    def from_nx(tensor) when is_struct(tensor, Nx.Tensor) do
      with {:ok, tensor} <- Image.Nx.transpose(tensor, Nx.shape(tensor), Nx.names(tensor)),
           {:ok, tensor_format} <- Image.BandFormat.image_format_from_nx(tensor) do
        {width, height, bands} = Nx.shape(tensor)
        binary = Nx.to_binary(tensor)
        Vix.Vips.Image.new_from_binary(binary, width, height, bands, tensor_format)
      end
    end
  end

  @doc """
  Returns a 512-bit difference hash as a binary.

  Image hashes can be used to compare the similarity
  of images. See `Image.hamming_distance/2`.

  dhash is generates a "difference hash" for a given image -- a
  perceptual hash based on Neal Krawetz's dHash algorithm in
  a [Hacker Factor](http://www.hackerfactor.com/blog/index.php?/archives/529-Kind-of-Like-That.html)
  blog entry.

  The code is adapted from the Ruby implementation in
  [dhash-vips](https://github.com/Nakilon/dhash-vips).

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ### Returns

  * `{:ok, 512-bit binary}` or

  * `{:error, reason}`

  """
  @doc since: "0.6.0"

  @spec dhash(image :: Vimage.t()) :: image_hash()
  def dhash(%Vimage{} = image, hash_size \\ 8) when is_integer(hash_size) and hash_size > 0 do
    alias Image.Math

    {:ok, convolution} = Image.Matrix.image_from_matrix([[1, -1]])

    image
    |> pixelate(hash_size)
    |> Operation.cast!(:VIPS_FORMAT_INT)
    |> Operation.conv!(convolution)
    |> crop!(1, 0, hash_size, hash_size)
    |> Math.greater_than!(0)
    |> Math.divide!(255)
    |> Operation.cast!(:VIPS_FORMAT_UCHAR)
    |> Vimage.write_to_binary()
  end

  defp pixelate(%Vimage{} = image, hash_size) do
    image
    |> resize!(hash_size + 1, height: hash_size, resize: :force)
    |> Operation.flatten!()
    |> to_colorspace!(:bw)
    |> Operation.extract_band!(0)
  end

  @doc false
  def convert_binary_to_hash(binary) do
    for << byte::integer-8-native <- binary >>, reduce: <<>> do
      acc ->
        <<_rest::bitstring-7, bit::bitstring>> = <<byte::integer-8-native>>
        <<acc :: bitstring, bit :: bitstring>>
    end
  end

  @doc """
  Returns the hamming distance of two images
  or two image hashes.

  A [hamming distance](https://en.wikipedia.org/wiki/Hamming_distance)
  gives an indication of the similarity of two images.

  In general, a hamming distance of less than `10` indicates
  that the images are very similar.  A distance of
  less than `20` suggests the images are quite similar. Any
  other distance suggests the images have little in common.

  ### Arguments

  * `image_1` is any `t:Vix.Vips.Image.t/0`

  * `image_2` is any `t:Vix.Vips.Image.t/0`

  Alternatively, both arguments may be image hashes
  returned by `Image.dhash/1`. Both arguments must
  be of the same type.

  ### Returns

  * `{:ok, hamming_distance}` where hamming distance is
    a positive integer or

  * `{:error, reason}`.

  """
  @doc since: "0.6.0"

  @spec hamming_distance(image_1 :: Vimage.t(), image_2 :: Vimage.t()) ::
    {:ok, non_neg_integer()} | {:error, error_message()}

  def hamming_distance(%Vimage{} = image_1, %Vimage{} = image_2) do
    with {:ok, hash_1} <- dhash(image_1),
         {:ok, hash_2} <- dhash(image_2) do
      hamming_distance(hash_1, hash_2)
    end
  end

  @spec hamming_distance(image_hash(), image_hash()) ::
    {:ok, non_neg_integer()} | {:error, error_message()}

  def hamming_distance(hash_1, hash_2) when is_binary(hash_1) and is_binary(hash_2) do
    hash_1
    |> :crypto.exor(hash_2)
    |> count_ones()
    |> wrap(:ok)
  end

  defp count_ones(binary) when is_binary(binary) do
    for(<< bit::1 <- binary >>, do: bit) |> Enum.sum
  end

  @doc """
  Returns the fast fourier transform (fft) of
  the given image.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`

  ### Returns

  * `{:ok, fft_image}` or

  * `{:error, reason}`

  ### Example

      Image.fft(image)

  """
  @spec fft(Vimage.t()) :: {:ok, Vimage.t()} | {:error, error_message()}
  def fft(%Vimage{} = image) do
    image
    |> to_colorspace!(:bw)
    |> Operation.fwfft!()
    |> Operation.wrap!()
    |> Operation.abs()
  end

  @doc """
  Returns the fast fourier transform (fft) of
  the given image returning an image or
  raising an exception.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`

  ### Returns

  * `fft_image` or

  * raises an exception

  ### Example

      Image.fft!(image)

  """
  @spec fft!(Vimage.t()) :: Vimage.t() | no_return()
  def fft!(%Vimage{} = image) do
    case fft(image) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Attempts top determine the distance
  from the perpendicular for a given image.

  The principle is that rotating the image
  by the skew angle should return an image
  in the upright position.

  The results are very image sensitive and
  perfect results are not guaranteed.

  The algorithm is an implementation of
  [this stackoverflow post](https://stackoverflow.com/questions/52474645/improve-a-picture-to-detect-the-characters-within-an-area/52502597#52502597).

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`

  ### Returns

  * `skew_angle` which is a float number
    of degrees the image is tilted from the
    upright.

  #### Example

      skew_angle = skew_angle(image)
      Image.rotate(image, skew_angle)

  """
  @spec skew_angle(Vimage.t()) :: float()
  def skew_angle(%Vimage{} = image) do
    {_columns, rows, []} =
      image
      |> fft!()
      |> to_rectangular_coordinates!()
      |> Operation.project!()

    {_v, _x, y} =
      rows
      |> Operation.gaussblur!(10)
      |> Image.Math.maxpos()

    # and turn to an angle in degrees we should counter-rotate by
    270 - 360 * y / height(rows)
  end

  @doc """
  Convert an image into a mask.

  Takes an image, extracts its alpha channel
  which holds the opacity information and
  inverts the content.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`

  ### Returns

  * `{:ok, mask}` or

  * `{:error, reason}`

  """
  @spec convert_to_mask(Vimage.t()) :: {:ok, Vimage.t()} | {:error, error_message()}
  def convert_to_mask(%Vimage{} = image) do
    if alpha_band = alpha_band(image) do
      {:ok, mask} = Operation.extract_band(image, alpha_band)
      Operation.invert(mask)
    else
      {:error, "Image has no alpha band"}
    end
  end

  @doc """
  Convert an image into a mask returning
  an image or raising an exception.

  Takes an image, extracts its alpha channel
  which holds the opacity information and
  inverts the content.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`

  ### Returns

  * `mask` image or

  * raises an exception

  """
  @spec convert_to_mask!(Vimage.t()) :: Vimage.t() | no_return()
  def convert_to_mask!(%Vimage{} = image) do
    case convert_to_mask(image) do
      {:ok, image} -> image
      {:error, reason} -> raise Image.Error, reason
    end
  end

  @doc """
  Returns a boolean based upon whether a given
  image has an alpha band.

  The determination is a heuristic so certainty
  cannot be guaranteed.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ### Returns

  * `true` or `false`

  """
  @spec has_alpha?(Vimage.t()) :: boolean()
  def has_alpha?(%Vimage{} = image) do
    Vimage.has_alpha?(image)
  end

  @doc """
  Returns the band number of the alpha
  channel of an image, or nil if it doesn't
  have one.

  The determination is a heuristic so certainty
  cannot be guaranteed.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`.

  ### Returns

  * An integer in the range `1..4` depending
    on the image interpretation. Returns `nil`
    if there is no alpha band.

  """
  @spec alpha_band(Vimage.t()) :: 1..4 | nil
  def alpha_band(%Vimage{} = image) do
    if has_alpha?(image) do
      Vimage.bands(image) - 1
    else
      nil
    end
  end

  @doc """
  Returns the number of operating system
  threads available for use by `libvips`.

  By default the number of threads will be
  the number of cores in the system.

  Since image processing is CPU intensive it
  may be appropriate to reduce the number of
  threads to be available to reduce the risk
  of CPU starvation for other workloads.

  See `Image.put_concurrency/1`.

  """
  @spec get_concurrency :: pos_integer()
  def get_concurrency do
    {:ok, concurrency} = Vix.Vips.concurrency_get()
    concurrency
  end

  @doc """
  Sets the number of available threads for use
  by `libvips`.

  By default this is the same as the number of
  cores in the system. Reducing this number may
  prevent CPU starvation for other workloads.

  ### Arguments

  * `concurrency` is a positive integer denoting
    the maximum number of threads that `libvips` will
    use for concurrency.

  ### Returns

  * `{:ok, updated_concurrency}`

  """
  @spec put_concurrency(pos_integer()) :: pos_integer()
  def put_concurrency(concurrency) when is_integer(concurrency) and concurrency > 0 do
    :ok = Vix.Vips.concurrency_set(concurrency)
    get_concurrency()
  end

  @doc """
  Returns the orientation of an image.

  ### Arguments

  * `image` is any `t:Vix.Vips.Image.t/0`

  * `options` is a keyword list of options

  ### Options

  * `:square_ratio` indicates when an image
    is to be considered square. It is a floating
    point indicator of the ratio between the width
    and height below which the image is considered
    square. The default is `0.0` meaning that the
    dimensions must be exactly equal in order for
    the image to be considered square.

  ### Returns

  * Either `:landscape`, `:portrait` or `:square`.

  ### Example

      iex> puppy = Image.open!(Path.expand("images/puppy.webp"))
      iex> Image.orientation(puppy, square_ratio: 0.05)
      :landscape

  """
  @spec orientation(Vimage.t()) :: orientation()
  def orientation(%Vimage{} = image, options \\ []) do
    square_ratio = Keyword.get(options, :square_ratio, @square_when_ratio_less_than)
    width = Image.width(image)
    height = Image.height(image)
    ratio = abs(1.0 - width / height)

    cond do
      ratio < square_ratio -> :square
      width > height -> :landscape
      height > width -> :portrait
    end
  end

  @doc """
  Returns the version of `libvips` in
  operation.

  """
  @spec vips_version :: {:ok, Version.t()}
  def vips_version do
    Vix.Vips.version()
    |> Version.parse()
  end

  defp wrap(item, atom) do
    {atom, item}
  end

  defp build_option_string(options, other_options) do
    "[" <> options <> "," <> join_options(other_options) <> "]"
  end

  defp build_option_string(options) do
    "[" <> join_options(options) <> "]"
  end

  defp join_options(options) do
    Enum.map_join(options, ",", fn {k, v} -> "#{k}=#{v}" end)
  end

  defp file_exists?(path) do
    if File.exists?(path, [:raw]), do: {:ok, path}, else: {:error, :enoent}
  end

  defp xy_offset(%Vimage{} = _image, _overlay, x, y) when is_number(x) and is_number(y) do
    {x, y}
  end

  defp xy_offset(%Vimage{} = base_image, %Vimage{} = overlay, x, y) do
    x = offset_from(x, Image.width(base_image), Image.width(overlay))
    y = offset_from(y, Image.height(base_image), Image.height(overlay))
    {x, y}
  end

  # Used for x offset
  defp offset_from(:left, _base_size, _overlay_size), do: 0
  defp offset_from(:right, base_size, overlay_size), do: base_size - overlay_size
  defp offset_from(:center, base_size, overlay_size), do: div(base_size, 2) - div(overlay_size, 2)

  # Used for y offset
  defp offset_from(:top, _base_size, _overlay_size), do: 0
  defp offset_from(:bottom, base_size, overlay_size), do: base_size - overlay_size
  defp offset_from(:middle, base_size, overlay_size), do: div(base_size, 2) - div(overlay_size, 2)

  defp offset_from(other, _base_size, _overlay_size) do
    raise ArgumentError, """
    Invalid offset position #{inspect other}.
    Valid positions are :left, :right, :middle, :top, :bottom, :center
    """
  end
end
