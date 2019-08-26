/*
* Copyright (c) 2018-2019, NVIDIA CORPORATION.  All rights reserved.
*
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
*     http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
*/

#include <exception>
#include <map>
#include <cuda_runtime.h>
#include <thrust/device_vector.h>
#include <thrust/for_each.h>
#include <thrust/count.h>
#include <rmm/rmm.h>
#include <rmm/thrust_rmm_allocator.h>

#include "NVStrings.h"

#include "./NVStringsImpl.h"
#include "../custring_view.cuh"
#include "../util.h"

//
struct url_encoder
{
    custring_view_array d_strings;
    size_t* d_offsets;
    bool bcompute_size_only{true};
    char* d_buffer{nullptr};
    custring_view_array d_results;

    __device__ void byte_to_hex( unsigned char byte, char* hex )
    {
        hex[0] = '0';
        if( byte >= 16 )
        {
            unsigned char hibyte = byte/16;
            hex[0] = hibyte < 10 ? '0'+hibyte : 'A'+(hibyte-10);
            byte = byte - (hibyte * 16);
        }
        hex[1] = byte < 10 ? '0'+byte : 'A'+(byte-10);
    }

    __device__ void operator()( unsigned int idx )
    {
        custring_view* dstr = d_strings[idx];
        if( !dstr )
            return;
        //
        char* buffer = d_buffer + d_offsets[idx];
        char* optr = buffer;
        int nbytes = 0;
        char hex[2]; // two-byte hex max
        for( auto itr = dstr->begin(); itr!=dstr->end(); itr++ )
        {
            Char ch = *itr;
            if( ch < 128 )
            {
                if( (ch>='0' && ch<='9') || // these are the characters
                    (ch>='A' && ch<='Z') || // that are not to be url
                    (ch>='a' && ch<='z') || // encoded -- just pass through
                    (ch=='.') || (ch=='_') || (ch=='~') || (ch=='-') )
                {
                    nbytes++;
                    if( !bcompute_size_only )
                    {
                        char* sptr = dstr->data() + itr.byte_offset();
                        copy_and_incr(optr,sptr,1);
                    }
                }
                else // url-encode everything else
                {
                    nbytes += 3;
                    if( !bcompute_size_only )
                    {
                        copy_and_incr(optr,(char*)"%",1);
                        byte_to_hex( (unsigned char)ch, hex);
                        copy_and_incr(optr,hex,2);
                    }
                }
            }
            else // these are to be utf-8 url-encoded
            {
                unsigned char char_bytes[4]; // holds utf-8 bytes
                unsigned int char_width = custring_view::Char_to_char(ch,(char*)char_bytes);
                nbytes += char_width * 3; // '%' plus 2 hex chars -- per byte: é is %C3%A9
                for( unsigned int chidx=0; !bcompute_size_only && (chidx < char_width); chidx++ )
                {
                    copy_and_incr(optr,(char*)"%",1);     // add percent '%'
                    byte_to_hex( char_bytes[chidx], hex); // convert to 2-char hex
                    copy_and_incr(optr,hex,2);            // copy hex chars
                }
            }
        }
        if( bcompute_size_only )
        {
            int size = custring_view::alloc_size(nbytes,nbytes);
            d_offsets[idx] = ALIGN_SIZE(size);
        }
        else
            d_results[idx] = custring_view::create_from(buffer,buffer,nbytes);
    }
};


NVStrings* NVStrings::url_encode()
{
    auto execpol = rmm::exec_policy(0);
    unsigned int count = size();
    // inputs
    custring_view_array d_strings = pImpl->getStringsPtr();
    rmm::device_vector<size_t> offsets(count,0);
    size_t* d_offsets = offsets.data().get();
    // outputs
    NVStrings* rtn = nullptr;
    char* d_buffer = nullptr;
    custring_view_array d_results = nullptr;

    // first loop will compute size output
    // 2nd loop will do the operation in the allocated memory
    enum scan_and_operate { scan, operate };
    auto op = scan;
    while(true)
    {
        thrust::for_each_n(execpol->on(0), thrust::make_counting_iterator<unsigned int>(0), count,
            url_encoder{d_strings,d_offsets,(op==scan),d_buffer,d_results});

        if( op==operate )
            break;
        op = operate;
        rtn = new NVStrings(count);
        d_buffer = rtn->pImpl->createMemoryFor(d_offsets);
        if( !d_buffer )
            break; // all nulls, ok
        // create offsets
        thrust::exclusive_scan(execpol->on(0),offsets.begin(),offsets.end(),offsets.begin());
        d_results = rtn->pImpl->getStringsPtr();
    }
    //
    return rtn;
}

struct url_decoder
{
    custring_view_array d_strings;
    size_t* d_offsets;
    bool bcompute_size_only{true};
    char* d_buffer;
    custring_view_array d_results;

    __device__ char hex_to_byte( char ch1, char ch2 )
    {
        unsigned char result = 0;
        if( ch1 >= '0' && ch1 <= '9' )
            result += (ch1-48);
        else if( ch1 >= 'A' && ch1 <= 'Z' )
            result += (ch1-55);
        else if( ch1 >='a' && ch1 <= 'z' )
            result += (ch1-87);
        result *= 16;
        if( ch2 >= '0' && ch2 <= '9' )
            result += (ch2-48);
        else if( ch2 >= 'A' && ch2 <= 'Z' )
            result += (ch2-55);
        else if( ch2 >='a' && ch2 <= 'z' )
            result += (ch2-87);
        return (char)result;
    }

    __device__ void operator()(unsigned int idx)
    {
        custring_view* dstr = d_strings[idx];
        if( !dstr )
            return;
        char* buffer = d_buffer + d_offsets[idx];
        char* optr = buffer;
        unsigned int nbytes = 0, nchars = 0;
        char* sptr = dstr->data();
        char* send = sptr + dstr->size();
        while( sptr < send )
        {
            char ch = *sptr++;
            if( ch != '%' )
            {
                ++nbytes;
                ++nchars;
                if( !bcompute_size_only )
                    copy_and_incr(optr, &ch, 1);
            }
            else if( sptr+1 < send )
            {
                ++nbytes;
                ch = *sptr++;
                nchars += (ch & 0xC0 != 0x80);
                ch = hex_to_byte( ch, *sptr++ );
                if( !bcompute_size_only )
                    copy_and_incr(optr, &ch, 1);
            }
        }
        if( bcompute_size_only )
        {
            int size = custring_view::alloc_size(nbytes,nchars);
            d_offsets[idx] = ALIGN_SIZE(size);
        }
        else
            d_results[idx] = custring_view::create_from(buffer,buffer,nbytes);
    }
};

NVStrings* NVStrings::url_decode()
{
    auto execpol = rmm::exec_policy(0);
    unsigned int count = size();
    // inputs
    custring_view_array d_strings = pImpl->getStringsPtr();
    rmm::device_vector<size_t> offsets(count,0);
    size_t* d_offsets = offsets.data().get();
    // outputs
    NVStrings* rtn = nullptr;
    char* d_buffer = nullptr;
    custring_view_array d_results = nullptr;

    // first loop will compute size output
    // 2nd loop will do the operation in the allocated memory
    enum scan_and_operate { scan, operate };
    auto op = scan;
    while(true)
    {
        thrust::for_each_n(execpol->on(0), thrust::make_counting_iterator<unsigned int>(0), count,
            url_decoder{d_strings,d_offsets,(op==scan),d_buffer,d_results});

        if( op==operate )
            break;
        op = operate;
        rtn = new NVStrings(count);
        d_buffer = rtn->pImpl->createMemoryFor(d_offsets);
        if( !d_buffer )
            break; // all nulls, ok
        // create offsets
        thrust::exclusive_scan(execpol->on(0),offsets.begin(),offsets.end(),offsets.begin());
        d_results = rtn->pImpl->getStringsPtr();
    }
    //
    return rtn;
}

